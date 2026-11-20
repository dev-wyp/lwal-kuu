-- Audited compensating reversal for supplier payments.
-- Requires 0044's verified allocation contract; does not delete or mutate the
-- source payment/allocation rows. A payment can only be fully reversed once.
begin;

create table if not exists public.supplier_payment_reversals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  supplier_payment_id uuid not null,
  amount numeric(14,2) not null check (amount > 0),
  reason text not null check (length(btrim(reason)) between 5 and 1000),
  idempotency_key text not null check (length(btrim(idempotency_key)) between 8 and 200),
  request_fingerprint text not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (organization_id, supplier_payment_id),
  unique (organization_id, idempotency_key),
  unique (organization_id, id),
  constraint supplier_payment_reversals_org_payment_fk
    foreign key (organization_id, supplier_payment_id)
    references public.supplier_payments(organization_id, id) on delete restrict
);

create index if not exists supplier_payment_reversals_org_created_idx
  on public.supplier_payment_reversals(organization_id, created_at desc);

create table if not exists public.supplier_payment_reversal_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  reversal_id uuid not null,
  purchase_id uuid not null,
  amount numeric(14,2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (organization_id, reversal_id, purchase_id),
  constraint supplier_reversal_allocations_org_reversal_fk
    foreign key (organization_id, reversal_id)
    references public.supplier_payment_reversals(organization_id, id) on delete restrict,
  constraint supplier_reversal_allocations_org_purchase_fk
    foreign key (organization_id, purchase_id)
    references public.purchases(organization_id, id) on delete restrict
);

create index if not exists supplier_payment_reversal_allocations_org_purchase_idx
  on public.supplier_payment_reversal_allocations(organization_id, purchase_id);

alter table public.supplier_payment_reversals enable row level security;
alter table public.supplier_payment_reversal_allocations enable row level security;
drop policy if exists supplier_payment_reversals_read_members on public.supplier_payment_reversals;
create policy supplier_payment_reversals_read_members on public.supplier_payment_reversals
  for select to authenticated
  using ((public.has_org_permission(organization_id,'purchases','view')
      and public.organization_has_plan_feature(organization_id,'supplier_payables'))
    or public.is_platform_admin());
drop policy if exists supplier_payment_reversal_allocations_read_members on public.supplier_payment_reversal_allocations;
create policy supplier_payment_reversal_allocations_read_members on public.supplier_payment_reversal_allocations
  for select to authenticated
  using ((public.has_org_permission(organization_id,'purchases','view')
      and public.organization_has_plan_feature(organization_id,'supplier_payables'))
    or public.is_platform_admin());
revoke all on public.supplier_payment_reversals, public.supplier_payment_reversal_allocations from public, anon, authenticated;
grant select on public.supplier_payment_reversals, public.supplier_payment_reversal_allocations to authenticated;
grant select on public.supplier_payment_reversals, public.supplier_payment_reversal_allocations to service_role;

create or replace function public.reverse_supplier_payment(
  p_org_id uuid,
  p_supplier_payment_id uuid,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_payment public.supplier_payments%rowtype;
  v_existing public.supplier_payment_reversals%rowtype;
  v_reversal_id uuid := gen_random_uuid();
  v_fingerprint text;
  v_allocation record;
  v_purchase public.purchases%rowtype;
  v_allocation_count integer := 0;
  v_allocated numeric(14,2) := 0;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'purchases','update') then raise exception 'Unauthorized'; end if;
  if p_reason is null or length(btrim(p_reason)) not between 5 and 1000 then
    raise exception 'A reversal reason between 5 and 1000 characters is required';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then
    raise exception 'A valid idempotency key is required';
  end if;

  v_fingerprint := md5(jsonb_build_object(
    'organization_id',p_org_id,
    'supplier_payment_id',p_supplier_payment_id,
    'reason',btrim(p_reason)
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(p_org_id::text||':supplier_payment_reversal:'||p_idempotency_key,0));

  select * into v_existing
  from public.supplier_payment_reversals r
  where r.organization_id=p_org_id and r.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.request_fingerprint is distinct from v_fingerprint then
      raise exception 'Idempotency key was already used for a different supplier payment reversal';
    end if;
    return jsonb_build_object('success',true,'reversal_id',v_existing.id,
      'supplier_payment_id',v_existing.supplier_payment_id,'amount',v_existing.amount,
      'created_at',v_existing.created_at,'replayed',true);
  end if;

  select * into v_payment
  from public.supplier_payments sp
  where sp.id=p_supplier_payment_id and sp.organization_id=p_org_id
  for update;
  if not found then raise exception 'Supplier payment does not belong to this organization'; end if;
  perform 1 from public.suppliers s
    where s.id=v_payment.supplier_id and s.organization_id=p_org_id
    for update;
  if not found then raise exception 'Supplier payment has no valid supplier in this organization'; end if;
  if exists(select 1 from public.supplier_payment_reversals r
      where r.organization_id=p_org_id and r.supplier_payment_id=v_payment.id) then
    raise exception 'Supplier payment is already reversed';
  end if;

  if v_payment.amount is null or v_payment.amount<=0 then raise exception 'Supplier payment amount is invalid'; end if;
  insert into public.supplier_payment_reversals(
    id,organization_id,supplier_payment_id,amount,reason,idempotency_key,request_fingerprint,created_by
  ) values (
    v_reversal_id,p_org_id,v_payment.id,v_payment.amount,btrim(p_reason),p_idempotency_key,v_fingerprint,v_user_id
  );

  -- Compensate each posted allocation in stable order. Source allocations remain
  -- immutable and are retained for audit/history.
  for v_allocation in
    select a.purchase_id,a.amount
    from public.supplier_payment_allocations a
    where a.organization_id=p_org_id and a.supplier_payment_id=v_payment.id
    order by a.purchase_id
    for update
  loop
    select * into v_purchase from public.purchases p
      where p.id=v_allocation.purchase_id and p.organization_id=p_org_id
      for update;
    if not found then raise exception 'An allocated purchase is missing or belongs to another organization'; end if;
    if v_purchase.supplier_id<>v_payment.supplier_id then raise exception 'Allocated purchase belongs to another supplier'; end if;
    if v_purchase.paid_amount<v_allocation.amount then raise exception 'Purchase paid balance is inconsistent; reversal stopped'; end if;
    update public.purchases set paid_amount=paid_amount-v_allocation.amount,updated_at=now()
      where id=v_purchase.id and organization_id=p_org_id;
    insert into public.supplier_payment_reversal_allocations(organization_id,reversal_id,purchase_id,amount)
      values(p_org_id,v_reversal_id,v_purchase.id,v_allocation.amount);
    v_allocated := v_allocated+v_allocation.amount;
    v_allocation_count := v_allocation_count+1;
  end loop;

  if v_allocated>v_payment.amount then raise exception 'Supplier payment allocations exceed the payment amount'; end if;

  -- Legacy receive_purchase payments have no allocation row but point to their
  -- single purchase. Preserve that relationship and compensate it once.
  if v_allocation_count=0 and v_payment.purchase_id is not null then
    select * into v_purchase from public.purchases p
      where p.id=v_payment.purchase_id and p.organization_id=p_org_id
      for update;
    if not found then raise exception 'Linked purchase is missing or belongs to another organization'; end if;
    if v_purchase.supplier_id<>v_payment.supplier_id then raise exception 'Linked purchase belongs to another supplier'; end if;
    if v_purchase.paid_amount<v_payment.amount then raise exception 'Purchase paid balance is inconsistent; reversal stopped'; end if;
    update public.purchases set paid_amount=paid_amount-v_payment.amount,updated_at=now()
      where id=v_purchase.id and organization_id=p_org_id;
    insert into public.supplier_payment_reversal_allocations(organization_id,reversal_id,purchase_id,amount)
      values(p_org_id,v_reversal_id,v_purchase.id,v_payment.amount);
  end if;

  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(p_org_id,v_user_id,'supplier_payment.reverse','supplier_payment',v_payment.id,
    jsonb_build_object('reversal_id',v_reversal_id,'amount',v_payment.amount,
      'reason',btrim(p_reason),'idempotency_key',p_idempotency_key,
      'allocated_amount',case when v_allocation_count=0 and v_payment.purchase_id is not null then v_payment.amount else v_allocated end));

  return jsonb_build_object('success',true,'reversal_id',v_reversal_id,
    'supplier_payment_id',v_payment.id,'amount',v_payment.amount,'replayed',false);
end;
$$;

revoke all on function public.reverse_supplier_payment(uuid,uuid,text,text) from public,anon;
grant execute on function public.reverse_supplier_payment(uuid,uuid,text,text) to authenticated;

-- Report balances net of reversals while preserving the original payment row.
create or replace view public.supplier_balances_summary as
select s.id as supplier_id,s.organization_id,s.name as supplier_name,s.phone,s.opening_balance,
  coalesce(purch_agg.total_purchases,0.00) as total_received_purchases,
  coalesce(pay_agg.total_paid,0.00) as total_payments_made,
  (s.opening_balance+coalesce(purch_agg.total_purchases,0.00)-coalesce(pay_agg.total_paid,0.00)) as current_payable
from public.suppliers s
left join (
  select supplier_id,organization_id,sum(total_amount) as total_purchases
  from public.purchases where status='received' group by supplier_id,organization_id
) purch_agg on purch_agg.supplier_id=s.id and purch_agg.organization_id=s.organization_id
left join (
  select sp.supplier_id,sp.organization_id,sum(sp.amount-coalesce(r.amount,0)) as total_paid
  from public.supplier_payments sp
  left join public.supplier_payment_reversals r
    on r.organization_id=sp.organization_id and r.supplier_payment_id=sp.id
  group by sp.supplier_id,sp.organization_id
) pay_agg on pay_agg.supplier_id=s.id and pay_agg.organization_id=s.organization_id
where s.is_active=true
  and public.has_org_membership(s.organization_id)
  and public.organization_has_plan_feature(s.organization_id,'supplier_payables');
alter view public.supplier_balances_summary set (security_invoker=true);

-- A reversed payment is a cash inflow on the reversal date. Keep the original
-- outflow on its original date; do not rewrite historical cash movement.
create or replace view public.cash_flow_performance as
with inflows as (
  select organization_id,date_trunc('month',payment_date)::date as period_start,sum(amount) as amount
  from public.payments
  where status='posted' and payment_type in ('customer_payment','other')
    and public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id,'cash_flow_report')
  group by organization_id,date_trunc('month',payment_date)::date
  union all
  select organization_id,date_trunc('month',sale_date)::date,sum(paid_amount)
  from public.sales
  where status='confirmed' and customer_id is null
    and public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id,'cash_flow_report')
  group by organization_id,date_trunc('month',sale_date)::date
  union all
  select r.organization_id,date_trunc('month',r.created_at)::date,sum(r.amount)
  from public.supplier_payment_reversals r
  where public.has_org_membership(r.organization_id)
    and public.organization_has_plan_feature(r.organization_id,'cash_flow_report')
  group by r.organization_id,date_trunc('month',r.created_at)::date
), outflows as (
  select organization_id,date_trunc('month',payment_date)::date as period_start,sum(amount) as amount
  from public.supplier_payments
  where public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id,'cash_flow_report')
  group by organization_id,date_trunc('month',payment_date)::date
  union all
  select organization_id,date_trunc('month',expense_date)::date,sum(amount)
  from public.expenses
  where public.has_org_membership(organization_id)
    and public.organization_has_plan_feature(organization_id,'cash_flow_report')
  group by organization_id,date_trunc('month',expense_date)::date
), all_periods as (
  select organization_id,period_start from inflows union
  select organization_id,period_start from outflows
), inflow_totals as (
  select organization_id,period_start,sum(amount) as cash_in from inflows group by organization_id,period_start
), outflow_totals as (
  select organization_id,period_start,sum(amount) as cash_out from outflows group by organization_id,period_start
)
select p.organization_id,p.period_start,
  coalesce(i.cash_in,0)::numeric as cash_in,
  coalesce(o.cash_out,0)::numeric as cash_out,
  (coalesce(i.cash_in,0)-coalesce(o.cash_out,0))::numeric as net_cash_flow
from all_periods p
left join inflow_totals i using(organization_id,period_start)
left join outflow_totals o using(organization_id,period_start);
alter view public.cash_flow_performance set (security_invoker=true);

notify pgrst,'reload schema';
commit;
