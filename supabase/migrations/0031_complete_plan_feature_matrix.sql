-- Make every existing plan matrix explicit for every active feature.
-- Existing assignments (including platform-admin customizations) are preserved.
-- Missing assignments are filled from the original tier definitions in 0019.
with plan_defaults(plan_id, enabled_features) as (
  values
    ('starter', array[
      'product_management','category_management','customer_management',
      'supplier_management','purchase_management','sales_management','cash_sales',
      'inventory_management','stock_adjustment','daily_sales_report',
      'basic_product_report','manual_data_export','max_users','max_products',
      'max_customers','max_suppliers','max_branches'
    ]::text[]),
    ('business', array[
      'product_management','category_management','customer_management',
      'supplier_management','purchase_management','sales_management','cash_sales',
      'credit_sales','partial_payments','customer_ledger','customer_debt_tracking',
      'supplier_payables','payment_receipt_mgmt','expense_management',
      'inventory_management','stock_adjustment','stock_transfer','low_stock_alerts',
      'multi_branch','daily_sales_report','basic_product_report',
      'monthly_yearly_reports','profit_estimation','excel_export',
      'basic_permissions','manual_data_export','max_users','max_products',
      'max_customers','max_suppliers','max_branches'
    ]::text[]),
    ('pro', array[
      'product_management','category_management','customer_management',
      'supplier_management','purchase_management','sales_management','cash_sales',
      'credit_sales','partial_payments','customer_ledger','customer_debt_tracking',
      'supplier_payables','payment_receipt_mgmt','expense_management',
      'inventory_management','stock_adjustment','stock_transfer','low_stock_alerts',
      'multi_branch','advanced_inventory','barcode_support','qr_support',
      'daily_sales_report','basic_product_report','monthly_yearly_reports',
      'customer_statement_pdf','supplier_statement_pdf','sales_analytics',
      'purchase_analytics','branch_reports','profit_loss_report','cash_flow_report',
      'profit_estimation','automated_reports','debt_reminders','excel_export',
      'manual_data_export','basic_permissions','advanced_permissions','audit_logs',
      'backup_restore','priority_support','max_users','max_products',
      'max_customers','max_suppliers','max_branches'
    ]::text[])
),
custom_plan_defaults as (
  select p.id as plan_id, array[]::text[] as enabled_features
  from public.plans p
  where p.id not in ('starter', 'business', 'pro')
),
plan_feature_matrix as (
  select p.id as plan_id, f.id as feature_id,
         f.feature_key = any(d.enabled_features) as is_enabled
  from (
    select * from plan_defaults
    union all
    select * from custom_plan_defaults
  ) d
  join public.plans p on p.id = d.plan_id
  cross join public.features f
  where f.is_active
)
insert into public.plan_features(plan_id, feature_id, is_enabled)
select plan_id, feature_id, is_enabled
from plan_feature_matrix
on conflict (plan_id, feature_id) do nothing;

-- Numeric feature limits are stored separately from Boolean plan features.
-- Backfill any missing limit rows from the plan's existing limit columns.
insert into public.plan_feature_limits(plan_id, feature_id, limit_value, limit_unit)
select p.id,
       f.id,
       case f.feature_key
         when 'max_users' then p.max_users
         when 'max_products' then p.max_products
         when 'max_customers' then p.max_customers
         when 'max_suppliers' then p.max_suppliers
         when 'max_branches' then p.max_branches
       end,
       case f.feature_key
         when 'max_users' then 'users'
         when 'max_products' then 'products'
         when 'max_customers' then 'customers'
         when 'max_suppliers' then 'suppliers'
         when 'max_branches' then 'branches'
       end
from public.plans p
cross join public.features f
where f.is_active
  and f.feature_type = 'limit'
on conflict (plan_id, feature_id) do nothing;
