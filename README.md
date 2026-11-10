# ShopFlow — Wholesale & Small Shop Management SaaS

ShopFlow is a production-ready, multi-tenant Software-as-a-Service (SaaS) platform built for wholesale distributors and retail shop owners. Initially optimized for Myanmar small businesses (with native Myanmar Kyat `MMK`, `Asia/Yangon` business timezone, and local mobile money workflows), its modular architecture easily expands internationally.

---

## Key Features

- **Multi-Tenant Isolation:** Complete organization-level data segregation enforced by PostgreSQL Row Level Security (RLS) on all tenant-owned tables.
- **Fast POS & Invoicing:** Mobile-friendly checkout register with barcode scanning, product lookups, cash sales, partial upfront deposits, and credit invoicing.
- **Dynamic Customer Credit Ledgers:** Non-drifting financial ledgers with date-range statement generation and multi-invoice FIFO payment allocations.
- **Immutable Stock Ledger:** Inventory movements (`stock_movements`) serve as the single source of truth, calculating weighted average costing and true gross profit margins.
- **Vendor Purchasing & Receiving:** Purchase order management with automatic inventory increments and supplier accounts payable.
- **Self-Service SaaS Onboarding:** Instant 14-day free trial auto-provisioning upon organization creation.
- **Subscription Management:** Starter, Business, and Pro tiers with usage meter limits and manual domestic payment verification.
- **Platform Super-Admin:** Global organization monitoring, manual payment approval workflows, and audit logging.

---

## Technology Stack

- **Frontend:** React 18, Vite, TypeScript (Strict Mode), Material UI (MUI v6), React Router v7, TanStack Query v5, React Hook Form, Zod.
- **Backend & Database:** Supabase, PostgreSQL 15+, Supabase Auth, Row Level Security, PostgreSQL Functions/RPCs, Supabase Edge Functions, Supabase Cron.
- **Architecture:** Modular Monolith.

---

## Getting Started

### 1. Installation

```bash
# Clone the repository
cd wholesale-erp

# Install dependencies
npm install
```

### 2. Configure Environment Variables

Copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

Set your Supabase credentials:
```ini
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-publishable-key
```

### 3. Database Migrations

Apply the ordered SQL migrations in `supabase/migrations/`:

```bash
supabase link --project-ref your-project-id
supabase db push
```

### 4. Run Development Server

```bash
npm run dev
```

Visit [http://localhost:3000](http://localhost:3000) in your browser.

---

## Project Structure

```
wholesale-erp/
├── docs/                               # System architecture & documentation
│   ├── architecture/
│   │   ├── 01-project-architecture.md
│   │   ├── 02-database-erd.md
│   │   ├── 03-database-migration-plan.md
│   │   ├── 04-business-workflows.md
│   │   └── 05-mvp-implementation-checklist.md
│   ├── deployment-guide.md
│   ├── admin-operations-guide.md
│   └── customer-onboarding-guide.md
├── supabase/
│   ├── migrations/                     # 10 dependency-ordered SQL migrations
│   └── functions/                      # Deno Edge Functions (send-email, webhooks)
├── src/
│   ├── components/                     # Reusable layouts, Navbar, Sidebar
│   ├── context/                        # Auth, Multi-Tenant Org, Notification providers
│   ├── modules/                        # Business domain modules
│   │   ├── public/                     # Landing & Pricing pages
│   │   ├── auth/                       # Login, Register, Forgot Password
│   │   ├── onboarding/                 # Self-service organization wizard
│   │   ├── dashboard/                  # KPI overview & analytics
│   │   ├── products/                   # Catalog, categories, units
│   │   ├── customers/                  # Customers, statements, credit ledgers
│   │   ├── suppliers/                  # Vendors & accounts payable
│   │   ├── purchases/                  # POs & goods receipt workflow
│   │   ├── inventory/                  # Stock movements ledger & adjustments
│   │   ├── sales/                      # POS, invoicing, printable receipts, reversals
│   │   ├── payments/                   # Customer receipts & invoice allocation
│   │   ├── expenses/                   # Operational expense tracking
│   │   ├── reports/                    # Daily/monthly sales, gross profit, CSV export
│   │   ├── settings/                   # Org configuration & team member roles
│   │   ├── subscription/               # Plan usage meters & upgrade flows
│   │   └── platform/                   # Platform super-admin dashboard
│   ├── routes/                         # React Router configuration
│   ├── theme/                          # Material UI theme
│   └── types/                          # TypeScript database schemas & domain types
└── tests/
    └── e2e/                            # Playwright end-to-end integration tests
```

---

## Quality & Verification Commands

```bash
# Type check TypeScript in strict mode
npx tsc --noEmit

# Run ESLint
npm run lint

# Build production bundle
npm run build

# Run Playwright E2E tests
npm run test:e2e
```
