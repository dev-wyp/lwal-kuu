create or replace function public.has_org_permission(p_org_id uuid, p_permission text, p_action text default 'view')
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  member_role text;
  allowed boolean;
begin
  if auth.uid() is null or public.is_platform_admin() then return true; end if;
  select role into member_role from public.organization_members where organization_id=p_org_id and user_id=auth.uid() and is_active;
  if member_role is null then return false; end if;
  if member_role in ('owner','admin') then return true; end if;
  if not public.organization_has_plan_feature(p_org_id,'advanced_permissions') then return true; end if;
  select case p_action when 'view' then can_view when 'create' then can_create when 'update' then can_update when 'delete' then can_delete else false end
    into allowed from public.organization_role_permissions where organization_id=p_org_id and role=member_role and permission_key=p_permission;
  if found then return coalesce(allowed,false); end if;
  if member_role='staff' then
    if p_action='view' then return p_permission in ('products','customers','sales','inventory'); end if;
    return p_permission in ('sales','customers') and p_action in ('create','update');
  end if;
  if member_role='manager' then return p_permission in ('products','customers','suppliers','sales','purchases','inventory','expenses') and p_action <> 'delete'; end if;
  return false;
end;
$$;

create or replace function public.capture_tenant_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  org_id uuid;
  entity_id uuid;
  before_row jsonb;
  after_row jsonb;
begin
  org_id := coalesce((to_jsonb(new)->>'organization_id')::uuid, (to_jsonb(old)->>'organization_id')::uuid);
  entity_id := coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid, gen_random_uuid());
  before_row := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end;
  after_row := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end;
  if tg_op='UPDATE' and before_row=after_row then return new; end if;
  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(org_id,auth.uid(),lower(tg_op)||':'||tg_table_name,tg_table_name,entity_id,jsonb_build_object('before',before_row,'after',after_row));
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

do $$
declare item record;
begin
  for item in select * from (values
    ('products','products'),('product_categories','products'),('customers','customers'),('suppliers','suppliers'),
    ('sales','sales'),('sale_items','sales'),('payments','sales'),('purchases','purchases'),('purchase_items','purchases'),
    ('supplier_payments','purchases'),('stock_adjustments','inventory'),('stock_movements','inventory'),('expenses','expenses'),('branches','inventory'),
    ('stock_transfers','inventory'),('stock_transfer_items','inventory')
  ) as permissions(table_name,permission_key) loop
    execute format('drop policy if exists advanced_role_read_permission on public.%I',item.table_name);
    execute format('create policy advanced_role_read_permission on public.%I as restrictive for select to authenticated using (public.has_org_permission(organization_id,%L,''view''))',item.table_name,item.permission_key);
  end loop;
end;
$$;

drop trigger if exists trg_audit_organization_role_permissions on public.organization_role_permissions;
create trigger trg_audit_organization_role_permissions after insert or update or delete on public.organization_role_permissions
for each row execute function public.capture_tenant_audit_log();

do $$
declare table_name text;
begin
  foreach table_name in array array['organization_settings','organization_members','support_tickets'] loop
    execute format('drop trigger if exists trg_audit_%I on public.%I',table_name,table_name);
    execute format('create trigger trg_audit_%I after insert or update or delete on public.%I for each row execute function public.capture_tenant_audit_log()',table_name,table_name);
  end loop;
end;
$$;

-- Keep supplier payments out of operating cash inflows; those are recorded in
-- supplier_payments and included on the outflow side of this report.
create or replace view public.cash_flow_performance as
with inflows as (
  select organization_id, date_trunc('month', payment_date)::date as period_start, sum(amount) as amount
  from public.payments
  where status='posted' and payment_type in ('customer_payment','other') and public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  select organization_id, date_trunc('month', sale_date)::date, sum(paid_amount)
  from public.sales
  where status='confirmed' and customer_id is null and public.has_org_membership(organization_id)
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
       (coalesce(inflow_totals.cash_in, 0)-coalesce(outflow_totals.cash_out, 0))::numeric as net_cash_flow
from all_periods
left join inflow_totals using (organization_id, period_start)
left join outflow_totals using (organization_id, period_start);

-- Views use the caller's RLS policies, so role-level read restrictions also cover report queries.
do $$
declare view_name text;
begin
  foreach view_name in array array[
    'product_sales_performance','monthly_sales_performance','yearly_sales_performance','purchase_analytics',
    'profit_loss_performance','cash_flow_performance','branch_stock_balances','branch_sales_performance',
    'product_stock_balances','customer_balances_summary','supplier_balances_summary','daily_sales_performance'
  ] loop
    execute format('alter view public.%I set (security_invoker = true)',view_name);
  end loop;
end;
$$;
