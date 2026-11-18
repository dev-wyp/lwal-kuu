-- Tenant-facing reports included by Business and Pro plans.
-- Every view filters by the caller's active organization membership.

create or replace view public.product_sales_performance as
select
  s.organization_id,
  p.id as product_id,
  p.sku,
  p.name as product_name,
  count(distinct s.id)::integer as invoice_count,
  sum(si.quantity) as units_sold,
  sum(si.total_amount) as revenue,
  sum(si.quantity * si.unit_cost) as cost_of_goods,
  sum(si.total_amount - (si.quantity * si.unit_cost)) as gross_profit
from public.sales s
join public.sale_items si on si.sale_id = s.id and si.organization_id = s.organization_id
join public.products p on p.id = si.product_id and p.organization_id = s.organization_id
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
group by s.organization_id, p.id, p.sku, p.name;

create or replace view public.monthly_sales_performance as
select
  s.organization_id,
  date_trunc('month', s.sale_date)::date as period_start,
  count(*)::integer as invoice_count,
  sum(s.total_amount) as revenue,
  sum(s.total_cost) as cost_of_goods,
  sum(s.total_amount - s.total_cost) as gross_profit
from public.sales s
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
group by s.organization_id, date_trunc('month', s.sale_date)::date;

create or replace view public.yearly_sales_performance as
select
  s.organization_id,
  date_trunc('year', s.sale_date)::date as period_start,
  count(*)::integer as invoice_count,
  sum(s.total_amount) as revenue,
  sum(s.total_cost) as cost_of_goods,
  sum(s.total_amount - s.total_cost) as gross_profit
from public.sales s
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
group by s.organization_id, date_trunc('year', s.sale_date)::date;

create or replace view public.purchase_analytics as
select
  p.organization_id,
  date_trunc('month', p.purchase_date)::date as period_start,
  p.supplier_id,
  s.name as supplier_name,
  count(p.id)::integer as purchase_count,
  sum(p.total_amount) as purchase_amount,
  sum(p.paid_amount) as paid_amount,
  sum(p.total_amount - p.paid_amount) as outstanding_amount
from public.purchases p
join public.suppliers s on s.id = p.supplier_id and s.organization_id = p.organization_id
where p.status = 'received'
  and public.has_org_membership(p.organization_id)
group by p.organization_id, date_trunc('month', p.purchase_date)::date, p.supplier_id, s.name;

create or replace view public.profit_loss_performance as
with sales_monthly as (
  select organization_id, date_trunc('month', sale_date)::date as period_start,
         sum(total_amount) as revenue, sum(total_cost) as cost_of_goods
  from public.sales
  where status = 'confirmed' and public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', sale_date)::date
), expenses_monthly as (
  select organization_id, date_trunc('month', expense_date)::date as period_start, sum(amount) as expenses
  from public.expenses
  where public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', expense_date)::date
), periods as (
  select organization_id, period_start from sales_monthly
  union
  select organization_id, period_start from expenses_monthly
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
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  -- Walk-in sales have no customer payment row; count their paid amount here.
  select organization_id, date_trunc('month', sale_date)::date, sum(paid_amount)
  from public.sales
  where status = 'confirmed' and customer_id is null and public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', sale_date)::date
), outflows as (
  select organization_id, date_trunc('month', payment_date)::date as period_start, sum(amount) as amount
  from public.supplier_payments
  where public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  select organization_id, date_trunc('month', expense_date)::date, sum(amount)
  from public.expenses
  where public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', expense_date)::date
), all_periods as (
  select organization_id, period_start from inflows
  union
  select organization_id, period_start from outflows
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

grant select on public.product_sales_performance, public.monthly_sales_performance,
  public.yearly_sales_performance, public.purchase_analytics,
  public.profit_loss_performance, public.cash_flow_performance to authenticated;
