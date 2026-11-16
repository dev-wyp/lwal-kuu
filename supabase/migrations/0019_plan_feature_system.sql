-- ==============================================================================
-- Migration: 0019_plan_feature_system.sql
-- Description: Normalized plan-feature tables, subscription_payments,
--              subscription_usage, subscription_audit_logs, org overrides.
-- ==============================================================================

-- -------------------------------------------------------------------------
-- A. Extend existing plans table (keep text PK)
-- -------------------------------------------------------------------------
alter table public.plans
  add column if not exists slug text unique,
  add column if not exists description text,
  add column if not exists currency text not null default 'MMK',
  add column if not exists is_public boolean not null default true,
  add column if not exists display_order integer not null default 0,
  add column if not exists max_customers integer not null default 100,
  add column if not exists max_suppliers integer not null default 20,
  add column if not exists max_branches integer not null default 1,
  add column if not exists updated_at timestamptz not null default now();

-- Back-fill slug
update public.plans set slug = id where slug is null;

-- Correct limits to match spec
update public.plans set
  name             = 'Starter',
  description      = 'Perfect for small retail shops getting started.',
  slug             = 'starter',
  display_order    = 1,
  monthly_price_mmk = 15000.00,
  yearly_price_mmk  = 150000.00,
  max_users        = 1,
  max_products     = 100,
  max_customers    = 100,
  max_suppliers    = 20,
  max_branches     = 1,
  is_active        = true,
  is_public        = true
where id = 'starter';

update public.plans set
  name             = 'Business',
  description      = 'For wholesale shops and businesses selling on credit.',
  slug             = 'business',
  display_order    = 2,
  monthly_price_mmk = 30000.00,
  yearly_price_mmk  = 300000.00,
  max_users        = 3,
  max_products     = 2000,
  max_customers    = -1,
  max_suppliers    = -1,
  max_branches     = 2,
  is_active        = true,
  is_public        = true
where id = 'business';

update public.plans set
  name             = 'Pro',
  description      = 'For growing businesses with multiple branches and employees.',
  slug             = 'pro',
  display_order    = 3,
  monthly_price_mmk = 60000.00,
  yearly_price_mmk  = 600000.00,
  max_users        = 10,
  max_products     = -1,
  max_customers    = -1,
  max_suppliers    = -1,
  max_branches     = 5,
  is_active        = true,
  is_public        = true
where id = 'pro';

-- -------------------------------------------------------------------------
-- B. features — master feature list
-- -------------------------------------------------------------------------
create table if not exists public.features (
  id           uuid primary key default gen_random_uuid(),
  feature_key  text not null unique,
  name         text not null,
  description  text,
  category     text not null default 'general',
  feature_type text not null default 'boolean'
                check (feature_type in ('boolean', 'limit', 'numeric', 'text')),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- C. plan_features — which features each plan includes
-- -------------------------------------------------------------------------
create table if not exists public.plan_features (
  id         uuid primary key default gen_random_uuid(),
  plan_id    text not null references public.plans(id) on delete cascade,
  feature_id uuid not null references public.features(id) on delete cascade,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (plan_id, feature_id)
);

-- -------------------------------------------------------------------------
-- D. plan_feature_limits — numeric limits per plan per feature
-- -------------------------------------------------------------------------
create table if not exists public.plan_feature_limits (
  id          uuid primary key default gen_random_uuid(),
  plan_id     text not null references public.plans(id) on delete cascade,
  feature_id  uuid not null references public.features(id) on delete cascade,
  limit_value integer not null default -1,   -- -1 = unlimited
  limit_unit  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (plan_id, feature_id)
);

-- -------------------------------------------------------------------------
-- E. organization_feature_overrides — per-org superadmin adjustments
-- -------------------------------------------------------------------------
create table if not exists public.organization_feature_overrides (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  feature_id      uuid not null references public.features(id) on delete cascade,
  is_enabled      boolean,
  limit_override  integer,
  starts_at       timestamptz not null default now(),
  expires_at      timestamptz,
  reason          text,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- F. subscription_payments — payment history (separate from events)
-- -------------------------------------------------------------------------
create table if not exists public.subscription_payments (
  id                    uuid primary key default gen_random_uuid(),
  subscription_id       uuid not null references public.subscriptions(id) on delete cascade,
  organization_id       uuid not null references public.organizations(id) on delete cascade,
  amount                numeric(14, 2) not null,
  currency              text not null default 'MMK',
  payment_method        text,
  transaction_reference text,
  payment_status        text not null default 'pending'
                          check (payment_status in ('pending','paid','failed','refunded')),
  paid_at               timestamptz,
  notes                 text,
  reviewed_by           uuid references auth.users(id) on delete set null,
  created_at            timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- G. subscription_usage — resource usage per org per feature_key
-- -------------------------------------------------------------------------
create table if not exists public.subscription_usage (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  feature_key     text not null,
  current_usage   integer not null default 0,
  period_start    date not null default current_date,
  period_end      date,
  updated_at      timestamptz not null default now(),
  unique (organization_id, feature_key, period_start)
);

-- -------------------------------------------------------------------------
-- H. subscription_audit_logs — immutable change log
-- -------------------------------------------------------------------------
create table if not exists public.subscription_audit_logs (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete set null,
  subscription_id uuid references public.subscriptions(id) on delete set null,
  action          text not null,
  old_value       jsonb,
  new_value       jsonb,
  performed_by    uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- Indexes
-- -------------------------------------------------------------------------
create index if not exists idx_plan_features_plan on public.plan_features (plan_id);
create index if not exists idx_plan_feature_limits_plan on public.plan_feature_limits (plan_id);
create index if not exists idx_org_feature_overrides_org on public.organization_feature_overrides (organization_id);
create index if not exists idx_org_feature_overrides_expires on public.organization_feature_overrides (expires_at);
create index if not exists idx_subscription_payments_org on public.subscription_payments (organization_id);
create index if not exists idx_subscription_payments_status on public.subscription_payments (payment_status);
create index if not exists idx_subscription_usage_org on public.subscription_usage (organization_id);
create index if not exists idx_subscription_audit_org on public.subscription_audit_logs (organization_id);
create index if not exists idx_subscription_audit_created on public.subscription_audit_logs (created_at desc);

-- -------------------------------------------------------------------------
-- RLS
-- -------------------------------------------------------------------------
alter table public.features enable row level security;
alter table public.plan_features enable row level security;
alter table public.plan_feature_limits enable row level security;
alter table public.organization_feature_overrides enable row level security;
alter table public.subscription_payments enable row level security;
alter table public.subscription_usage enable row level security;
alter table public.subscription_audit_logs enable row level security;

-- features: public read
create policy "features_read_all"
  on public.features for select using (true);
create policy "features_write_admin"
  on public.features for all using (public.is_platform_admin());

-- plan_features: public read
create policy "plan_features_read_all"
  on public.plan_features for select using (true);
create policy "plan_features_write_admin"
  on public.plan_features for all using (public.is_platform_admin());

-- plan_feature_limits: public read
create policy "plan_feature_limits_read_all"
  on public.plan_feature_limits for select using (true);
create policy "plan_feature_limits_write_admin"
  on public.plan_feature_limits for all using (public.is_platform_admin());

-- organization_feature_overrides
create policy "org_overrides_read_member"
  on public.organization_feature_overrides for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "org_overrides_write_admin"
  on public.organization_feature_overrides for all
  using (public.is_platform_admin());

-- subscription_payments
create policy "sub_payments_read_member"
  on public.subscription_payments for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "sub_payments_write_admin"
  on public.subscription_payments for all
  using (public.is_platform_admin());

-- subscription_usage
create policy "sub_usage_read_member"
  on public.subscription_usage for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "sub_usage_write_admin"
  on public.subscription_usage for all
  using (public.is_platform_admin());

-- subscription_audit_logs: platform admin only
create policy "audit_logs_admin_only"
  on public.subscription_audit_logs for all
  using (public.is_platform_admin());

-- -------------------------------------------------------------------------
-- I. Seed features master list
-- -------------------------------------------------------------------------
insert into public.features (feature_key, name, description, category, feature_type) values
  -- Core
  ('product_management',      'Product Management',       'Manage products and catalog',               'core',      'boolean'),
  ('category_management',     'Category Management',      'Manage product categories',                 'core',      'boolean'),
  ('customer_management',     'Customer Management',      'Manage customers',                          'core',      'boolean'),
  ('supplier_management',     'Supplier Management',      'Manage suppliers',                          'core',      'boolean'),
  ('purchase_management',     'Purchase Management',      'Create and manage purchase orders',         'core',      'boolean'),
  ('sales_management',        'Sales Management',         'Create and manage sales',                   'core',      'boolean'),
  ('cash_sales',              'Cash Sales',               'Sell with immediate cash payment',          'core',      'boolean'),
  -- Finance
  ('credit_sales',            'Credit Sales',             'Sell on credit (accounts receivable)',      'finance',   'boolean'),
  ('partial_payments',        'Partial Payments',         'Accept partial payments on invoices',       'finance',   'boolean'),
  ('customer_ledger',         'Customer Ledger',          'Track customer balances and history',       'finance',   'boolean'),
  ('customer_debt_tracking',  'Customer Debt Tracking',   'Track outstanding customer debts',          'finance',   'boolean'),
  ('supplier_payables',       'Supplier Payables',        'Track supplier payments and balances',      'finance',   'boolean'),
  ('payment_receipt_mgmt',    'Payment & Receipt Mgmt',   'Manage payments and receipts',              'finance',   'boolean'),
  ('expense_management',      'Expense Management',       'Track and manage business expenses',        'finance',   'boolean'),
  -- Inventory
  ('inventory_management',    'Inventory Management',     'Basic stock tracking',                      'inventory', 'boolean'),
  ('stock_adjustment',        'Stock Adjustment',         'Manually adjust stock levels',              'inventory', 'boolean'),
  ('stock_transfer',          'Stock Transfer',           'Transfer stock between branches',           'inventory', 'boolean'),
  ('low_stock_alerts',        'Low Stock Alerts',         'Get notified when stock is low',            'inventory', 'boolean'),
  ('advanced_inventory',      'Advanced Inventory',       'Advanced inventory management features',    'inventory', 'boolean'),
  ('barcode_support',         'Barcode Support',          'Barcode scanning support',                  'inventory', 'boolean'),
  ('qr_support',              'QR Support',               'QR code scanning support',                  'inventory', 'boolean'),
  -- Branch & Multi-org
  ('multi_branch',            'Multi-Branch',             'Manage multiple branches',                  'org',       'boolean'),
  -- Reports
  ('daily_sales_report',      'Daily Sales Report',       'View daily sales summary',                  'reports',   'boolean'),
  ('basic_product_report',    'Basic Product Report',     'Basic product performance report',          'reports',   'boolean'),
  ('monthly_yearly_reports',  'Monthly & Yearly Reports', 'Monthly and yearly financial reports',      'reports',   'boolean'),
  ('customer_statement_pdf',  'Customer Statement PDF',   'Generate PDF customer statements',          'reports',   'boolean'),
  ('supplier_statement_pdf',  'Supplier Statement PDF',   'Generate PDF supplier statements',          'reports',   'boolean'),
  ('sales_analytics',         'Sales Analytics',          'Advanced sales analytics and charts',       'reports',   'boolean'),
  ('purchase_analytics',      'Purchase Analytics',       'Advanced purchase analytics',               'reports',   'boolean'),
  ('branch_reports',          'Branch Reports',           'Per-branch performance reports',            'reports',   'boolean'),
  ('profit_loss_report',      'Profit & Loss Report',     'Full profit and loss statement',            'reports',   'boolean'),
  ('cash_flow_report',        'Cash Flow Report',         'Cash flow summary report',                  'reports',   'boolean'),
  ('profit_estimation',       'Profit Estimation',        'Estimate profit margins on sales',          'reports',   'boolean'),
  -- Automation
  ('automated_reports',       'Automated Reports',        'Automatically generated daily/weekly reports','automation','boolean'),
  ('debt_reminders',          'Debt Reminders',           'Automated debt reminder notifications',     'automation','boolean'),
  -- Export
  ('manual_data_export',      'Manual Data Export',       'Export data manually (CSV/basic)',          'export',    'boolean'),
  ('excel_export',            'Excel Export',             'Export reports to Excel format',            'export',    'boolean'),
  -- Access & Security
  ('basic_permissions',       'Basic User Permissions',   'Basic role-based user permissions',         'security',  'boolean'),
  ('advanced_permissions',    'Advanced Permissions',     'Advanced role-based access control',        'security',  'boolean'),
  ('audit_logs',              'Audit Logs',               'Full audit trail of all changes',           'security',  'boolean'),
  ('backup_restore',          'Backup & Restore',         'Backup and restore data support',           'security',  'boolean'),
  -- Support
  ('priority_support',        'Priority Support',         'Priority customer support access',          'support',   'boolean'),
  -- Limits (feature_type = limit)
  ('max_users',               'User Limit',               'Maximum number of active users',            'limits',    'limit'),
  ('max_products',            'Product Limit',            'Maximum number of active products',         'limits',    'limit'),
  ('max_customers',           'Customer Limit',           'Maximum number of active customers',        'limits',    'limit'),
  ('max_suppliers',           'Supplier Limit',           'Maximum number of active suppliers',        'limits',    'limit'),
  ('max_branches',            'Branch Limit',             'Maximum number of branches',                'limits',    'limit')
on conflict (feature_key) do update set
  name        = excluded.name,
  description = excluded.description,
  category    = excluded.category,
  feature_type = excluded.feature_type,
  updated_at  = now();

-- -------------------------------------------------------------------------
-- J. Seed plan_features (which features each plan has enabled)
-- -------------------------------------------------------------------------
-- Helper: seed for a plan using feature_key list
do $$
declare
  v_starter_features  text[] := array[
    'product_management','category_management','customer_management',
    'supplier_management','purchase_management','sales_management',
    'cash_sales','inventory_management','stock_adjustment',
    'daily_sales_report','basic_product_report','manual_data_export',
    'max_users','max_products','max_customers','max_suppliers','max_branches'
  ];
  v_business_features text[] := array[
    'product_management','category_management','customer_management',
    'supplier_management','purchase_management','sales_management',
    'cash_sales','credit_sales','partial_payments','customer_ledger',
    'customer_debt_tracking','supplier_payables','payment_receipt_mgmt',
    'expense_management','inventory_management','stock_adjustment',
    'stock_transfer','low_stock_alerts','multi_branch',
    'daily_sales_report','basic_product_report','monthly_yearly_reports',
    'profit_estimation','excel_export','basic_permissions',
    'manual_data_export',
    'max_users','max_products','max_customers','max_suppliers','max_branches'
  ];
  v_pro_features text[] := array[
    'product_management','category_management','customer_management',
    'supplier_management','purchase_management','sales_management',
    'cash_sales','credit_sales','partial_payments','customer_ledger',
    'customer_debt_tracking','supplier_payables','payment_receipt_mgmt',
    'expense_management','inventory_management','stock_adjustment',
    'stock_transfer','low_stock_alerts','multi_branch',
    'advanced_inventory','barcode_support','qr_support',
    'daily_sales_report','basic_product_report','monthly_yearly_reports',
    'customer_statement_pdf','supplier_statement_pdf','sales_analytics',
    'purchase_analytics','branch_reports','profit_loss_report',
    'cash_flow_report','profit_estimation','automated_reports',
    'debt_reminders','excel_export','manual_data_export',
    'basic_permissions','advanced_permissions','audit_logs','backup_restore',
    'priority_support',
    'max_users','max_products','max_customers','max_suppliers','max_branches'
  ];
  v_key text;
  v_fid uuid;
begin
  -- Starter
  foreach v_key in array v_starter_features loop
    select id into v_fid from public.features where feature_key = v_key;
    if found then
      insert into public.plan_features (plan_id, feature_id, is_enabled)
      values ('starter', v_fid, true)
      on conflict (plan_id, feature_id) do update set is_enabled = true, updated_at = now();
    end if;
  end loop;

  -- Business (all business features enabled)
  foreach v_key in array v_business_features loop
    select id into v_fid from public.features where feature_key = v_key;
    if found then
      insert into public.plan_features (plan_id, feature_id, is_enabled)
      values ('business', v_fid, true)
      on conflict (plan_id, feature_id) do update set is_enabled = true, updated_at = now();
    end if;
  end loop;

  -- Pro (all pro features enabled)
  foreach v_key in array v_pro_features loop
    select id into v_fid from public.features where feature_key = v_key;
    if found then
      insert into public.plan_features (plan_id, feature_id, is_enabled)
      values ('pro', v_fid, true)
      on conflict (plan_id, feature_id) do update set is_enabled = true, updated_at = now();
    end if;
  end loop;
end $$;

-- -------------------------------------------------------------------------
-- K. Seed plan_feature_limits
-- -------------------------------------------------------------------------
do $$
declare
  v_limits record;
  v_fid    uuid;
begin
  for v_limits in
    select * from (values
      -- (plan_id, feature_key, limit_value, limit_unit)
      ('starter',  'max_users',     1,    'users'),
      ('starter',  'max_products',  100,  'products'),
      ('starter',  'max_customers', 100,  'customers'),
      ('starter',  'max_suppliers', 20,   'suppliers'),
      ('starter',  'max_branches',  1,    'branches'),
      ('business', 'max_users',     3,    'users'),
      ('business', 'max_products',  2000, 'products'),
      ('business', 'max_customers', -1,   'customers'),
      ('business', 'max_suppliers', -1,   'suppliers'),
      ('business', 'max_branches',  2,    'branches'),
      ('pro',      'max_users',     10,   'users'),
      ('pro',      'max_products',  -1,   'products'),
      ('pro',      'max_customers', -1,   'customers'),
      ('pro',      'max_suppliers', -1,   'suppliers'),
      ('pro',      'max_branches',  5,    'branches')
    ) as t(plan_id, feature_key, limit_value, limit_unit)
  loop
    select id into v_fid from public.features where feature_key = v_limits.feature_key;
    if found then
      insert into public.plan_feature_limits (plan_id, feature_id, limit_value, limit_unit)
      values (v_limits.plan_id, v_fid, v_limits.limit_value, v_limits.limit_unit)
      on conflict (plan_id, feature_id) do update
        set limit_value = excluded.limit_value,
            limit_unit  = excluded.limit_unit,
            updated_at  = now();
    end if;
  end loop;
end $$;

