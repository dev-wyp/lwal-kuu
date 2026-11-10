# ShopFlow — MVP Implementation Checklist

This checklist tracks progress across the 8 sequential implementation phases specified in the project requirements.

---

## Phase 1: Project Foundation and Authentication
- [ ] Initialize/Refactor project foundation with Vite, React 19/18, TypeScript (strict mode), and MUI v6.
- [ ] Install required frontend dependencies: `@mui/material`, `@emotion/react`, `@emotion/styled`, `@mui/icons-material`, `react-router-dom`, `@tanstack/react-query`, `react-hook-form`, `@hookform/resolvers`, `zod`, `axios`, `@supabase/supabase-js`.
- [ ] Configure strict TypeScript (`tsconfig.json`), ESLint, and environment configuration (`.env.example`).
- [ ] Set up theme provider with Material UI, responsive breakpoints, and custom typography.
- [ ] Build Supabase Auth integration (Session handling, login, registration, password recovery).
- [ ] Implement public landing page (`/`), pricing page (`/pricing`), and authentication routes (`/login`, `/register`, `/forgot-password`).
- [ ] Verify TypeScript and ESLint pass without warnings.

## Phase 2: Multi-Tenant Organization and Security
- [ ] Author Core SQL migrations: `profiles`, `organizations`, `organization_members`, `organization_settings`, `audit_logs`.
- [ ] Implement PostgreSQL security functions: `has_org_membership()`, `get_user_org_role()`, `is_platform_admin()`.
- [ ] Configure RLS policies ensuring tenant isolation across all core tables.
- [ ] Build Organization Context & Switcher in the React frontend.
- [ ] Implement Self-Service Onboarding flow (New organization wizard, 14-day trial auto-provisioning).
- [ ] Build Member management UI (Invite members, assign roles: Owner, Admin, Manager, Staff).
- [ ] Verify RLS isolation preventing cross-tenant access.

## Phase 3: Product, Customer, and Supplier Management
- [ ] Author SQL migrations: `product_categories`, `units`, `products`, `customers`, `suppliers`.
- [ ] Add unique constraints (SKU per org, Unit code per org, Category per org).
- [ ] Implement RLS policies for Products, Customers, and Suppliers.
- [ ] Build Product Catalog UI (`/app/products`, `/app/categories`):
  - Product list with search, filter, pagination, category chips, unit indicators.
  - Create/edit product drawer with Zod validation and image/pricing fields.
- [ ] Build Customer Management UI (`/app/customers`):
  - Customer directory with search, contact details, and credit limits.
- [ ] Build Supplier Management UI (`/app/suppliers`):
  - Supplier directory with contact details and purchase balance.

## Phase 4: Purchase and Inventory
- [ ] Author SQL migrations: `stock_movements`, `stock_adjustments`, `purchases`, `purchase_items`, `supplier_payments`.
- [ ] Implement atomic RPC `receive_purchase()` with weighted average cost recalculation.
- [ ] Implement atomic RPC `record_supplier_payment()`.
- [ ] Build Stock Balance reconcilable SQL view `product_stock_balances`.
- [ ] Build Purchases UI (`/app/purchases`):
  - Purchase order creation with line items, cost entry, and supplier selection.
  - Receive purchase action triggering stock movement generation.
- [ ] Build Inventory UI (`/app/inventory`):
  - Current stock on hand with low-stock warnings.
  - Stock movement audit ledger (Opening, Purchase In, Sales Out, Adjustments).
  - Stock adjustment dialog (damages, count corrections).

## Phase 5: Sales and Payment Allocation
- [ ] Author SQL migrations: `sales`, `sale_items`, `payments`, `payment_allocations`.
- [ ] Implement atomic RPC `confirm_sale()`:
  - Validates stock availability.
  - Decrements inventory via `stock_movements`.
  - Records payments and allocations atomically.
  - Enforces server-side totals and idempotency.
- [ ] Implement atomic RPC `void_or_reverse_sale()` with compensatory stock reversals.
- [ ] Implement atomic RPC `record_customer_payment_and_allocate()` for multi-invoice credit payments.
- [ ] Build POS & Sales UI (`/app/sales`):
  - Fast product search and keyboard-friendly item addition.
  - Customer selection with credit balance indicator.
  - Cash, credit sale, and partial payment handling.
  - Invoice modal with printable receipt layout.
  - Void transaction modal with mandatory reason.

## Phase 6: Customer Ledger and Reports
- [ ] Create financial SQL views:
  - `customer_ledger_view` (Opening + Sales - Payments = Outstanding Balance).
  - `supplier_ledger_view` (Opening + Purchases - Payments = Outstanding Payable).
  - `gross_profit_report_view` (Revenue - Cost of Goods Sold = Profit & Margin).
  - `daily_sales_summary_view`.
- [ ] Build Customer Ledger & Statement UI (`/app/customers/:id`):
  - Running balance timeline, date range filtering, PDF/printable statement export.
- [ ] Build Dashboard (`/app/dashboard`):
  - Today's sales, Monthly sales, Receivables, Payables, Stock value, Low stock alerts.
- [ ] Build Comprehensive Reports (`/app/reports`):
  - Sales by Product, Sales by Customer, Gross Profit report, Expenses report.
  - CSV export capability.

## Phase 7: Subscription and Automation
- [ ] Author SQL migrations: `plans`, `subscriptions`, `subscription_events`, `usage_limits`.
- [ ] Implement server-side usage limit verification triggers/functions.
- [ ] Build Subscription UI (`/app/subscription`):
  - Current plan status, trial countdown, usage progress bars.
  - Upgrade/renew plan modal with payment provider abstraction (KBZPay, Wave, Bank transfer).
- [ ] Build Platform Admin Portal (`/platform/*`):
  - Organization directory, active subscriptions, manual payment approvals, audit logs.
- [ ] Set up Supabase Edge Functions / Cron outlines:
  - Daily sales summaries, subscription expiration checks, low-stock notifications.

## Phase 8: Testing, Security Review, and Deployment
- [ ] Write Playwright end-to-end tests for critical business paths.
- [ ] Run full TypeScript checks and ESLint verification.
- [ ] Perform security and RLS policy review (Ensure no service role leak, all tables protected).
- [ ] Document environment variables (`.env.example`) and deployment instructions.
- [ ] Prepare Admin Operation Guide & Customer Onboarding Guide.

