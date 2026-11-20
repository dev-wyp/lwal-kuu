-- Supplier payment workflow: scoped request keys, allocations and advances.
-- Additive migration: preserve prior supplier payment rows and balances.
begin;

-- Stop before changing anything if an installation has an allocation table whose
-- shape differs from this migration's contract. Inspect its columns and constraints
-- first; never create a parallel ledger or guess how legacy references map.
do $$
declare missing_columns text[]; incompatible_columns text[]; extra_required_columns text[];
begin
  if to_regclass('public.supplier_payment_allocations') is not null then
    select array_agg(required.column_name order by required.column_name)
      into missing_columns
      from (values
        ('id','uuid'),('organization_id','uuid'),('supplier_payment_id','uuid'),
        ('purchase_id','uuid'),('amount','numeric')
      ) as required(column_name,expected_udt_name)
      where not exists (
        select 1 from information_schema.columns c
        where c.table_schema='public'
          and c.table_name='supplier_payment_allocations'
          and c.column_name=required.column_name
      );
    select array_agg(required.column_name||' (expected '||required.expected_udt_name||', found '||c.udt_name||')' order by required.column_name)
      into incompatible_columns
      from (values
        ('id','uuid'),('organization_id','uuid'),('supplier_payment_id','uuid'),
        ('purchase_id','uuid'),('amount','numeric')
      ) as required(column_name,expected_udt_name)
      join information_schema.columns c
        on c.table_schema='public' and c.table_name='supplier_payment_allocations'
       and c.column_name=required.column_name
      where c.udt_name<>required.expected_udt_name;
    select array_agg(c.column_name order by c.column_name)
      into extra_required_columns
      from information_schema.columns c
      where c.table_schema='public' and c.table_name='supplier_payment_allocations'
        and c.is_nullable='NO' and c.column_default is null
        and c.is_identity='NO' and c.is_generated='NEVER'
        and c.column_name not in ('organization_id','supplier_payment_id','purchase_id','amount');
    if missing_columns is not null or incompatible_columns is not null or extra_required_columns is not null then
      raise exception 'Existing public.supplier_payment_allocations is incompatible; missing columns: %; incompatible types: %; additional required columns with no default: %. Run the read-only schema inspection and adapt migration 0044 before retrying.', coalesce(array_to_string(missing_columns, ', '),'none'), coalesce(array_to_string(incompatible_columns, ', '),'none'), coalesce(array_to_string(extra_required_columns, ', '),'none');
    end if;
  end if;
end;
$$;

alter table public.supplier_payments
  add column if not exists idempotency_key text,
  add column if not exists request_fingerprint text;
create unique index if not exists supplier_payments_org_idempotency_uidx
  on public.supplier_payments(organization_id,idempotency_key)
  where idempotency_key is not null;
create unique index if not exists supplier_payments_org_id_uidx
  on public.supplier_payments(organization_id,id);

create table if not exists public.supplier_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  supplier_payment_id uuid not null references public.supplier_payments(id) on delete cascade,
  purchase_id uuid not null references public.purchases(id) on delete restrict,
  amount numeric(14,2) not null check(amount>0),
  created_at timestamptz not null default now(),
  unique(organization_id,supplier_payment_id,purchase_id)
);
create index if not exists supplier_payment_allocations_org_purchase_idx
  on public.supplier_payment_allocations(organization_id,purchase_id);
create unique index if not exists supplier_payment_allocations_org_id_uidx
  on public.supplier_payment_allocations(organization_id,id);

do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.supplier_payment_allocations'::regclass and conname='supplier_allocations_org_payment_fk') then
    alter table public.supplier_payment_allocations add constraint supplier_allocations_org_payment_fk
      foreign key(organization_id,supplier_payment_id) references public.supplier_payments(organization_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.supplier_payment_allocations'::regclass and conname='supplier_allocations_org_purchase_fk') then
    alter table public.supplier_payment_allocations add constraint supplier_allocations_org_purchase_fk
      foreign key(organization_id,purchase_id) references public.purchases(organization_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.supplier_payments'::regclass and conname='supplier_payments_org_purchase_fk') then
    alter table public.supplier_payments add constraint supplier_payments_org_purchase_fk
      foreign key(organization_id,purchase_id) references public.purchases(organization_id,id)
      on delete set null (purchase_id) not valid;
  end if;
end;
$$;

-- Existing supplier_payments.purchase_id remains authoritative for legacy rows.
-- Do not backfill allocation rows here: legacy cross-tenant references require a
-- separate read-only mismatch review before creating child rows under NOT VALID FKs.

alter table public.supplier_payment_allocations enable row level security;
drop policy if exists supplier_payment_allocations_read_members on public.supplier_payment_allocations;
create policy supplier_payment_allocations_read_members on public.supplier_payment_allocations
  for select to authenticated using(public.has_org_membership(organization_id) or public.is_platform_admin());
revoke all on public.supplier_payment_allocations from public,anon,authenticated;
grant select on public.supplier_payment_allocations to authenticated,service_role;

-- Supplier payments affect balances and must only be written through validated,
-- transactional RPCs such as receive_purchase and record_supplier_payment_and_allocate.
revoke insert,update,delete on public.supplier_payments from public,anon,authenticated;
grant select on public.supplier_payments to authenticated;

create or replace function public.record_supplier_payment_and_allocate(
  p_org_id uuid,
  p_supplier_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_allocations jsonb default '[]'::jsonb,
  p_reference_number text default null,
  p_notes text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_payment public.supplier_payments%rowtype;
  v_purchase public.purchases%rowtype;
  v_alloc jsonb;
  v_purchase_id uuid;
  v_alloc_amount numeric(14,2);
  v_total_allocated numeric(14,2) := 0;
  v_amount numeric(14,2);
  v_subtotal numeric(14,2);
  v_purchase_total numeric(14,2);
  v_payment_number text;
  v_fingerprint text;
  v_payment_id uuid;
  v_single_purchase uuid;
  v_supplier_opening numeric(14,2);
  v_supplier_due numeric(14,2);
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'purchases','update') then raise exception 'Unauthorized'; end if;
  if not public.organization_has_plan_feature(p_org_id,'supplier_payables') then raise exception 'Supplier payments are not available on the current plan'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
  v_amount := round(p_amount,2);
  if v_amount<=0 then raise exception 'Payment amount is below supported currency precision'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then
    raise exception 'Unsupported payment method';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then
    raise exception 'A valid idempotency key is required';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations)<>'array' then raise exception 'Allocations must be a JSON array'; end if;
  if not exists(select 1 from public.suppliers s where s.id=p_supplier_id and s.organization_id=p_org_id and s.is_active) then
    raise exception 'Supplier does not belong to this organization or is inactive';
  end if;

  if exists(select 1 from jsonb_array_elements(p_allocations) x(value)
      group by value->>'purchase_id' having count(*)>1) then raise exception 'Duplicate purchase allocation'; end if;
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by value->>'purchase_id' loop
    if jsonb_typeof(v_alloc)<>'object' or nullif(v_alloc->>'purchase_id','') is null or nullif(v_alloc->>'amount','') is null then
      raise exception 'Each allocation needs a purchase_id and amount';
    end if;
    v_alloc_amount := (v_alloc->>'amount')::numeric(14,2);
    if v_alloc_amount<=0 then raise exception 'Allocation amount must be positive'; end if;
    v_total_allocated := v_total_allocated+v_alloc_amount;
  end loop;
  if v_total_allocated>v_amount then raise exception 'Allocations cannot exceed the payment amount'; end if;
  if jsonb_array_length(p_allocations)=1 then v_single_purchase := (p_allocations->0->>'purchase_id')::uuid; end if;
  select md5(jsonb_build_object(
    'organization_id',p_org_id,'supplier_id',p_supplier_id,'amount',v_amount,
    'payment_method',p_payment_method,'reference_number',p_reference_number,'notes',p_notes,
    'allocations',(select coalesce(jsonb_agg(value order by value->>'purchase_id'),'[]'::jsonb)
      from jsonb_array_elements(p_allocations))
  )::text) into v_fingerprint;

  select * into v_payment from public.supplier_payments sp
    where sp.organization_id=p_org_id and sp.idempotency_key=p_idempotency_key for update;
  if found then
    if v_payment.request_fingerprint is distinct from v_fingerprint then
      raise exception 'Idempotency key was already used for a different supplier payment';
    end if;
    return jsonb_build_object('success',true,'payment_id',v_payment.id,
      'payment_number',v_payment.payment_number,'amount',v_payment.amount,
      'allocated_amount',coalesce((select sum(a.amount) from public.supplier_payment_allocations a
        where a.organization_id=p_org_id and a.supplier_payment_id=v_payment.id),0),
      'unallocated_amount',v_payment.amount-coalesce((select sum(a.amount) from public.supplier_payment_allocations a
        where a.organization_id=p_org_id and a.supplier_payment_id=v_payment.id),0));
  end if;

  -- Serialize all new payments for a supplier so concurrent invoice payments
  -- cannot exceed the supplier's organization-wide payable. Unallocated amounts
  -- are allowed as advances; only allocated portions must fit current payable.
  select s.opening_balance into v_supplier_opening from public.suppliers s
    where s.id=p_supplier_id and s.organization_id=p_org_id for update;
  select greatest(coalesce(v_supplier_opening,0)
      + coalesce((select sum(p.total_amount) from public.purchases p
        where p.organization_id=p_org_id and p.supplier_id=p_supplier_id and p.status='received'),0)
      - coalesce((select sum(sp.amount) from public.supplier_payments sp
        where sp.organization_id=p_org_id and sp.supplier_id=p_supplier_id),0),0)
    into v_supplier_due;
  if v_total_allocated>v_supplier_due then raise exception 'Allocated payment exceeds supplier payable balance after existing advances'; end if;

  -- Stable invoice lock order prevents concurrent payments exceeding a payable.
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by (value->>'purchase_id')::uuid loop
    v_purchase_id := (v_alloc->>'purchase_id')::uuid;
    v_alloc_amount := (v_alloc->>'amount')::numeric(14,2);
    select * into v_purchase from public.purchases p
      where p.id=v_purchase_id and p.organization_id=p_org_id for update;
    if not found then raise exception 'Purchase does not belong to this organization'; end if;
    if v_purchase.supplier_id<>p_supplier_id then raise exception 'Purchase belongs to another supplier'; end if;
    if v_purchase.status<>'received' then raise exception 'Only received purchases can be allocated for payment'; end if;
    if coalesce(v_purchase.tax_amount,0)<>0 then raise exception 'Purchase tax requires an organization tax rule before payment'; end if;
    select coalesce(sum(round(pi.quantity*pi.unit_cost,2)),0)::numeric(14,2) into v_subtotal
      from public.purchase_items pi where pi.purchase_id=v_purchase_id and pi.organization_id=p_org_id;
    if v_purchase.discount_amount<0 or v_purchase.discount_amount>v_subtotal then raise exception 'Purchase discount exceeds item subtotal'; end if;
    v_purchase_total := round(v_subtotal-v_purchase.discount_amount,2);
    if v_alloc_amount>greatest(v_purchase_total-coalesce(v_purchase.paid_amount,0),0) then
      raise exception 'Allocation exceeds purchase payable balance';
    end if;
    update public.purchases set subtotal=v_subtotal,total=v_purchase_total,total_amount=v_purchase_total,
      paid_amount=coalesce(paid_amount,0)+v_alloc_amount,updated_at=now()
      where id=v_purchase_id and organization_id=p_org_id;
  end loop;

  v_payment_number := public.next_document_number(p_org_id,'supplier_payment');
  insert into public.supplier_payments(organization_id,supplier_id,purchase_id,payment_number,payment_date,
    amount,payment_method,reference_number,notes,created_by,idempotency_key,request_fingerprint)
  values(p_org_id,p_supplier_id,v_single_purchase,v_payment_number,current_date,v_amount,p_payment_method,
    p_reference_number,p_notes,v_user_id,p_idempotency_key,v_fingerprint)
  returning id into v_payment_id;
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by (value->>'purchase_id')::uuid loop
    insert into public.supplier_payment_allocations(organization_id,supplier_payment_id,purchase_id,amount)
    values(p_org_id,v_payment_id,(v_alloc->>'purchase_id')::uuid,(v_alloc->>'amount')::numeric(14,2));
  end loop;
  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(p_org_id,v_user_id,'supplier_payment.create','supplier_payment',v_payment_id,
    jsonb_build_object('payment_number',v_payment_number,'amount',v_amount,
      'allocated_amount',v_total_allocated,'supplier_id',p_supplier_id,'idempotency_key',p_idempotency_key));
  return jsonb_build_object('success',true,'payment_id',v_payment_id,'payment_number',v_payment_number,
    'amount',v_amount,'allocated_amount',v_total_allocated,'unallocated_amount',v_amount-v_total_allocated);
end;
$$;

revoke all on function public.record_supplier_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) from public,anon;
grant execute on function public.record_supplier_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;

