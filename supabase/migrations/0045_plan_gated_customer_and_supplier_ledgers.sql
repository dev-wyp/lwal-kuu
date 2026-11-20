-- Enforce Business/Pro ledger entitlements at the database boundary.
-- This migration changes read views, restrictive read policies, and the
-- customer statement RPC. It does not update or remove business rows.

create or replace view public.customer_balances_summary as
select
  c.id as customer_id,
  c.organization_id,
  c.name as customer_name,
  c.phone,
  c.credit_limit,
  c.opening_balance,
  coalesce(sales_agg.total_sales, 0.00) as total_confirmed_sales,
  coalesce(pay_agg.total_payments, 0.00) as total_payments_received,
  (c.opening_balance + coalesce(sales_agg.total_sales, 0.00) - coalesce(pay_agg.total_payments, 0.00)) as current_balance
from public.customers c
left join (
  select customer_id, organization_id, sum(total_amount) as total_sales
  from public.sales
  where status = 'confirmed'
  group by customer_id, organization_id
) sales_agg on sales_agg.customer_id = c.id and sales_agg.organization_id = c.organization_id
left join (
  select customer_id, organization_id, sum(amount) as total_payments
  from public.payments
  where status = 'posted'
  group by customer_id, organization_id
) pay_agg on pay_agg.customer_id = c.id and pay_agg.organization_id = c.organization_id
where c.is_active = true
  and public.has_org_membership(c.organization_id)
  and (
    public.organization_has_plan_feature(c.organization_id, 'customer_ledger')
    or public.organization_has_plan_feature(c.organization_id, 'customer_debt_tracking')
  );

create or replace view public.supplier_balances_summary as
select
  s.id as supplier_id,
  s.organization_id,
  s.name as supplier_name,
  s.phone,
  s.opening_balance,
  coalesce(purch_agg.total_purchases, 0.00) as total_received_purchases,
  coalesce(pay_agg.total_paid, 0.00) as total_payments_made,
  (s.opening_balance + coalesce(purch_agg.total_purchases, 0.00) - coalesce(pay_agg.total_paid, 0.00)) as current_payable
from public.suppliers s
left join (
  select supplier_id, organization_id, sum(total_amount) as total_purchases
  from public.purchases
  where status = 'received'
  group by supplier_id, organization_id
) purch_agg on purch_agg.supplier_id = s.id and purch_agg.organization_id = s.organization_id
left join (
  select supplier_id, organization_id, sum(amount) as total_paid
  from public.supplier_payments
  group by supplier_id, organization_id
) pay_agg on pay_agg.supplier_id = s.id and pay_agg.organization_id = s.organization_id
where s.is_active = true
  and public.has_org_membership(s.organization_id)
  and public.organization_has_plan_feature(s.organization_id, 'supplier_payables');

-- Views execute using caller rights where supported, so base-table RLS and
-- advanced-role read policies continue to apply as well as these plan checks.
alter view public.customer_balances_summary set (security_invoker = true);
alter view public.supplier_balances_summary set (security_invoker = true);

-- Report-page FeatureGate checks are not an authorization boundary. Apply
-- each report entitlement inside its view so direct PostgREST reads obey the
-- same plan matrix.
create or replace view public.daily_sales_performance as
select organization_id, sale_date, count(id) as total_invoices,
       sum(total_amount) as total_revenue, sum(total_cost) as total_cogs,
       sum(total_amount - total_cost) as gross_profit,
       case when sum(total_amount) > 0
         then round(((sum(total_amount - total_cost) / sum(total_amount)) * 100), 2)
         else 0.00 end as gross_margin_percentage
from public.sales
where status = 'confirmed'
  and public.has_org_membership(organization_id)
  and public.organization_has_plan_feature(organization_id, 'daily_sales_report')
group by organization_id, sale_date;

create or replace view public.product_sales_performance as
select s.organization_id, p.id as product_id, p.sku, p.name as product_name,
       count(distinct s.id)::integer as invoice_count, sum(si.quantity) as units_sold,
       sum(si.total_amount) as revenue, sum(si.quantity * si.unit_cost) as cost_of_goods,
       sum(si.total_amount - (si.quantity * si.unit_cost)) as gross_profit
from public.sales s
join public.sale_items si on si.sale_id = s.id and si.organization_id = s.organization_id
join public.products p on p.id = si.product_id and p.organization_id = s.organization_id
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
  and public.organization_has_plan_feature(s.organization_id, 'basic_product_report')
group by s.organization_id, p.id, p.sku, p.name;

create or replace view public.monthly_sales_performance as
select s.organization_id, date_trunc('month', s.sale_date)::date as period_start,
       count(*)::integer as invoice_count, sum(s.total_amount) as revenue,
       sum(s.total_cost) as cost_of_goods, sum(s.total_amount - s.total_cost) as gross_profit
from public.sales s
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
  and public.organization_has_plan_feature(s.organization_id, 'monthly_yearly_reports')
group by s.organization_id, date_trunc('month', s.sale_date)::date;

create or replace view public.yearly_sales_performance as
select s.organization_id, date_trunc('year', s.sale_date)::date as period_start,
       count(*)::integer as invoice_count, sum(s.total_amount) as revenue,
       sum(s.total_cost) as cost_of_goods, sum(s.total_amount - s.total_cost) as gross_profit
from public.sales s
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
  and public.organization_has_plan_feature(s.organization_id, 'monthly_yearly_reports')
group by s.organization_id, date_trunc('year', s.sale_date)::date;

create or replace view public.purchase_analytics as
select p.organization_id, date_trunc('month', p.purchase_date)::date as period_start,
       p.supplier_id, s.name as supplier_name, count(p.id)::integer as purchase_count,
       sum(p.total_amount) as purchase_amount, sum(p.paid_amount) as paid_amount,
       sum(p.total_amount - p.paid_amount) as outstanding_amount
from public.purchases p
join public.suppliers s on s.id = p.supplier_id and s.organization_id = p.organization_id
where p.status = 'received'
  and public.has_org_membership(p.organization_id)
  and public.organization_has_plan_feature(p.organization_id, 'purchase_analytics')
group by p.organization_id, date_trunc('month', p.purchase_date)::date, p.supplier_id, s.name;

create or replace view public.profit_loss_performance as
with sales_monthly as (
  select organization_id, date_trunc('month', sale_date)::date as period_start,
         sum(total_amount) as revenue, sum(total_cost) as cost_of_goods
  from public.sales
  where status = 'confirmed' and public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id, 'profit_loss_report')
  group by organization_id, date_trunc('month', sale_date)::date
), expenses_monthly as (
  select organization_id, date_trunc('month', expense_date)::date as period_start,
         sum(amount) as expenses
  from public.expenses
  where public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id, 'profit_loss_report')
  group by organization_id, date_trunc('month', expense_date)::date
), periods as (
  select organization_id, period_start from sales_monthly
  union select organization_id, period_start from expenses_monthly
)
select periods.organization_id, periods.period_start,
       coalesce(sales_monthly.revenue, 0)::numeric as revenue,
       coalesce(sales_monthly.cost_of_goods, 0)::numeric as cost_of_goods,
       (coalesce(sales_monthly.revenue, 0) - coalesce(sales_monthly.cost_of_goods, 0))::numeric as gross_profit,
       coalesce(expenses_monthly.expenses, 0)::numeric as operating_expenses,
       (coalesce(sales_monthly.revenue, 0) - coalesce(sales_monthly.cost_of_goods, 0)
         - coalesce(expenses_monthly.expenses, 0))::numeric as net_operating_profit
from periods
left join sales_monthly using (organization_id, period_start)
left join expenses_monthly using (organization_id, period_start);

create or replace view public.cash_flow_performance as
with inflows as (
  select organization_id, date_trunc('month', payment_date)::date as period_start, sum(amount) as amount
  from public.payments
  where status = 'posted' and payment_type in ('customer_payment','other')
    and public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id, 'cash_flow_report')
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  select organization_id, date_trunc('month', sale_date)::date, sum(paid_amount)
  from public.sales
  where status = 'confirmed' and customer_id is null
    and public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id, 'cash_flow_report')
  group by organization_id, date_trunc('month', sale_date)::date
), outflows as (
  select organization_id, date_trunc('month', payment_date)::date as period_start, sum(amount) as amount
  from public.supplier_payments
  where public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id, 'cash_flow_report')
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  select organization_id, date_trunc('month', expense_date)::date, sum(amount)
  from public.expenses
  where public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id, 'cash_flow_report')
  group by organization_id, date_trunc('month', expense_date)::date
), all_periods as (
  select organization_id, period_start from inflows
  union select organization_id, period_start from outflows
), inflow_totals as (
  select organization_id, period_start, sum(amount) as cash_in from inflows group by organization_id, period_start
), outflow_totals as (
  select organization_id, period_start, sum(amount) as cash_out from outflows group by organization_id, period_start
)
select all_periods.organization_id, all_periods.period_start,
       coalesce(inflow_totals.cash_in, 0)::numeric as cash_in,
       coalesce(outflow_totals.cash_out, 0)::numeric as cash_out,
       (coalesce(inflow_totals.cash_in, 0) - coalesce(outflow_totals.cash_out, 0))::numeric as net_cash_flow
from all_periods
left join inflow_totals using (organization_id, period_start)
left join outflow_totals using (organization_id, period_start);

create or replace view public.branch_sales_performance as
select s.organization_id, s.branch_id, b.name as branch_name,
       count(*)::integer as invoice_count, sum(s.total_amount) as revenue,
       sum(s.total_cost) as cost_of_goods, sum(s.total_amount - s.total_cost) as gross_profit
from public.sales s
join public.branches b on b.id = s.branch_id and b.organization_id = s.organization_id
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
  and public.organization_has_plan_feature(s.organization_id, 'branch_reports')
group by s.organization_id, s.branch_id, b.name;

create or replace view public.branch_stock_balances as
select b.organization_id, b.id as branch_id, b.name as branch_name,
       p.id as product_id, p.sku, p.name, p.name as product_name,
       u.code as unit_code, u.name as unit_name, p.sale_price,
       coalesce(sum(m.quantity), 0)::numeric as stock_on_hand, p.average_cost,
       (coalesce(sum(m.quantity), 0) * p.average_cost)::numeric as stock_value,
       p.low_stock_threshold, (coalesce(sum(m.quantity), 0) <= p.low_stock_threshold) as is_low_stock
from public.branches b
join public.products p on p.organization_id = b.organization_id and p.is_active
join public.units u on u.id = p.unit_id
left join public.stock_movements m
  on m.branch_id = b.id and m.product_id = p.id and m.organization_id = p.organization_id
where b.is_active
  and public.has_org_membership(b.organization_id)
  and public.organization_has_plan_feature(b.organization_id, 'multi_branch')
group by b.organization_id, b.id, b.name, p.id, p.sku, p.name,
         u.code, u.name, p.sale_price, p.average_cost, p.low_stock_threshold;

alter view public.daily_sales_performance set (security_invoker = true);
alter view public.product_sales_performance set (security_invoker = true);
alter view public.monthly_sales_performance set (security_invoker = true);
alter view public.yearly_sales_performance set (security_invoker = true);
alter view public.purchase_analytics set (security_invoker = true);
alter view public.profit_loss_performance set (security_invoker = true);
alter view public.cash_flow_performance set (security_invoker = true);
alter view public.branch_sales_performance set (security_invoker = true);
alter view public.branch_stock_balances set (security_invoker = true);

-- Payment rows and allocations expose customer ledger details even when a
-- caller bypasses the ledger screens and queries base tables directly.
alter table public.payments enable row level security;
drop policy if exists customer_payment_plan_entitlement_select on public.payments;
create policy customer_payment_plan_entitlement_select
  on public.payments as restrictive for select to authenticated
  using (
    public.is_platform_admin()
    or (
      public.has_org_membership(organization_id)
      and public.has_org_permission(organization_id, 'customers', 'view')
      and (
        public.organization_has_plan_feature(organization_id, 'payment_receipt_mgmt')
        or public.organization_has_plan_feature(organization_id, 'customer_ledger')
        or public.organization_has_plan_feature(organization_id, 'customer_debt_tracking')
      )
    )
  );

alter table public.payment_allocations enable row level security;
drop policy if exists customer_payment_allocation_plan_entitlement_select on public.payment_allocations;
create policy customer_payment_allocation_plan_entitlement_select
  on public.payment_allocations as restrictive for select to authenticated
  using (
    public.is_platform_admin()
    or (
      public.has_org_membership(organization_id)
      and public.has_org_permission(organization_id, 'customers', 'view')
      and (
        public.organization_has_plan_feature(organization_id, 'payment_receipt_mgmt')
        or public.organization_has_plan_feature(organization_id, 'customer_ledger')
        or public.organization_has_plan_feature(organization_id, 'customer_debt_tracking')
      )
    )
  );

-- Supplier payment rows are part of the Business/Pro payables module. Keep
-- their existing membership policy and require the plan entitlement as an
-- additional restrictive condition for authenticated direct table reads.
alter table public.supplier_payments enable row level security;
drop policy if exists supplier_payments_plan_entitlement_select on public.supplier_payments;
create policy supplier_payments_plan_entitlement_select
  on public.supplier_payments as restrictive for select to authenticated
  using (
    public.is_platform_admin()
    or (
      public.has_org_membership(organization_id)
      and public.has_org_permission(organization_id, 'suppliers', 'view')
      and public.organization_has_plan_feature(organization_id, 'supplier_payables')
    )
  );

create or replace function public.get_customer_statement(
  p_org_id uuid,
  p_customer_id uuid,
  p_start_date date default null,
  p_end_date date default null
)
returns table (
  transaction_date date,
  transaction_type text,
  reference_number text,
  description text,
  debit numeric(14, 2),
  credit numeric(14, 2),
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;
  if not public.has_org_permission(p_org_id, 'customers', 'view') then
    raise exception 'Your organization role does not allow customer ledger access';
  end if;
  if not (
    public.organization_has_plan_feature(p_org_id, 'customer_ledger')
    or public.organization_has_plan_feature(p_org_id, 'customer_debt_tracking')
  ) then
    raise exception 'Customer ledger is not available on the current plan';
  end if;
  if not exists (
    select 1 from public.customers c
    where c.id = p_customer_id and c.organization_id = p_org_id
  ) then
    raise exception 'Customer does not belong to this organization';
  end if;

  return query
  select
    s.sale_date,
    'Sale Invoice'::text,
    s.invoice_number,
    'Confirmed Sale'::text,
    s.total_amount,
    0.00::numeric(14, 2),
    s.created_at
  from public.sales s
  where s.organization_id = p_org_id
    and s.customer_id = p_customer_id
    and s.status = 'confirmed'
    and (p_start_date is null or s.sale_date >= p_start_date)
    and (p_end_date is null or s.sale_date <= p_end_date)

  union all

  select
    p.payment_date,
    'Customer Payment'::text,
    p.payment_number,
    coalesce(p.payment_method, 'Payment Received'),
    0.00::numeric(14, 2),
    p.amount,
    p.created_at
  from public.payments p
  where p.organization_id = p_org_id
    and p.customer_id = p_customer_id
    and p.status = 'posted'
    and (p_start_date is null or p.payment_date >= p_start_date)
    and (p_end_date is null or p.payment_date <= p_end_date)
  order by 1 asc, 7 asc;
end;
$$;

revoke all on function public.get_customer_statement(uuid, uuid, date, date) from public, anon;
grant execute on function public.get_customer_statement(uuid, uuid, date, date) to authenticated;
