-- ==============================================================================
-- Migration: 0009_reporting_views.sql
-- Description: Financial views for Customer Ledger, Supplier Ledger, Gross Profit, and Sales Summaries.
-- ==============================================================================

-- 1. Customer Outstanding Balance & Ledger Summary View
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
where c.is_active = true;

-- 2. Supplier Outstanding Payable Summary View
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
where s.is_active = true;

-- 3. Daily Sales & Gross Profit View
create or replace view public.daily_sales_performance as
select
  organization_id,
  sale_date,
  count(id) as total_invoices,
  sum(total_amount) as total_revenue,
  sum(total_cost) as total_cogs,
  sum(total_amount - total_cost) as gross_profit,
  case
    when sum(total_amount) > 0 then round(((sum(total_amount - total_cost) / sum(total_amount)) * 100), 2)
    else 0.00
  end as gross_margin_percentage
from public.sales
where status = 'confirmed'
group by organization_id, sale_date;

-- 4. Customer Detailed Transaction Ledger RPC
-- Dynamically returns chronological entries (opening, sales, payments, reversals)
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

  return query
  -- Sales (Debits - increases receivable)
  select
    s.sale_date as transaction_date,
    'Sale Invoice'::text as transaction_type,
    s.invoice_number as reference_number,
    'Confirmed Sale'::text as description,
    s.total_amount as debit,
    0.00::numeric(14, 2) as credit,
    s.created_at
  from public.sales s
  where s.organization_id = p_org_id
    and s.customer_id = p_customer_id
    and s.status = 'confirmed'
    and (p_start_date is null or s.sale_date >= p_start_date)
    and (p_end_date is null or s.sale_date <= p_end_date)

  union all

  -- Payments (Credits - decreases receivable)
  select
    p.payment_date as transaction_date,
    'Customer Payment'::text as transaction_type,
    p.payment_number as reference_number,
    coalesce(p.payment_method, 'Payment Received') as description,
    0.00::numeric(14, 2) as debit,
    p.amount as credit,
    p.created_at
  from public.payments p
  where p.organization_id = p_org_id
    and p.customer_id = p_customer_id
    and p.status = 'posted'
    and (p_start_date is null or p.payment_date >= p_start_date)
    and (p_end_date is null or p.payment_date <= p_end_date)

  order by transaction_date asc, created_at asc;
end;
$$;

