-- Extend the existing supplier allocation relation without renaming or dropping
-- legacy columns. The production legacy contract uses org_id/payment_id; the
-- application contract uses organization_id/supplier_payment_id.
begin;

do $$
declare
  relation_oid regclass := to_regclass('public.supplier_payment_allocations');
  has_legacy_org boolean;
  has_legacy_payment boolean;
  bad_types text[];
  bad_count bigint;
begin
  if relation_oid is null then
    raise exception 'public.supplier_payment_allocations is missing; refusing to create a second allocation ledger';
  end if;

  select array_agg(req.column_name||' expected '||req.expected_type||', found '||coalesce(c.udt_name,'missing') order by req.column_name)
    into bad_types
  from (values
    ('id','uuid'),('purchase_id','uuid'),('amount','numeric')
  ) req(column_name,expected_type)
  left join information_schema.columns c
    on c.table_schema='public' and c.table_name='supplier_payment_allocations' and c.column_name=req.column_name
  where c.column_name is null or c.udt_name<>req.expected_type;
  if bad_types is not null then
    raise exception 'Unsupported supplier allocation schema: %',array_to_string(bad_types,', ');
  end if;

  select exists(select 1 from information_schema.columns where table_schema='public' and table_name='supplier_payment_allocations' and column_name='org_id'),
         exists(select 1 from information_schema.columns where table_schema='public' and table_name='supplier_payment_allocations' and column_name='payment_id')
    into has_legacy_org,has_legacy_payment;
  if has_legacy_org is distinct from has_legacy_payment then
    raise exception 'Unsupported partial legacy allocation mapping: org_id and payment_id must either both exist or both be absent';
  end if;
  if has_legacy_org then
    select array_agg(req.column_name||' expected '||req.expected_type||', found '||c.udt_name order by req.column_name)
      into bad_types
    from (values ('org_id','uuid'),('payment_id','uuid')) req(column_name,expected_type)
    join information_schema.columns c
      on c.table_schema='public' and c.table_name='supplier_payment_allocations' and c.column_name=req.column_name
    where c.udt_name<>req.expected_type;
    if bad_types is not null then raise exception 'Unsupported legacy allocation column types: %',array_to_string(bad_types,', '); end if;
  end if;
end;
$$;

alter table public.supplier_payment_allocations
  add column if not exists organization_id uuid,
  add column if not exists supplier_payment_id uuid;

do $$
declare
  has_legacy_org boolean;
  has_legacy_payment boolean;
  mismatch_count bigint;
begin
  select exists(select 1 from information_schema.columns where table_schema='public' and table_name='supplier_payment_allocations' and column_name='org_id'),
         exists(select 1 from information_schema.columns where table_schema='public' and table_name='supplier_payment_allocations' and column_name='payment_id')
    into has_legacy_org,has_legacy_payment;

  if has_legacy_org and has_legacy_payment then
    execute 'select count(*) from public.supplier_payment_allocations where (organization_id is not null and organization_id is distinct from org_id) or (supplier_payment_id is not null and supplier_payment_id is distinct from payment_id)'
      into mismatch_count;
    if mismatch_count>0 then raise exception 'Legacy and canonical supplier allocation identifiers conflict on % rows; no data was changed',mismatch_count; end if;

    -- The relation is empty in the inspected production state. For populated
    -- installations, only map values after proving both parents and tenant agree.
    execute 'select count(*) from public.supplier_payment_allocations a left join public.supplier_payments sp on sp.id=a.payment_id left join public.purchases pu on pu.id=a.purchase_id where a.org_id is null or a.payment_id is null or a.purchase_id is null or a.amount is null or a.amount<=0 or sp.id is null or pu.id is null or a.org_id<>sp.organization_id or a.org_id<>pu.organization_id or sp.supplier_id<>pu.supplier_id'
      into mismatch_count;
    if mismatch_count>0 then raise exception 'Legacy allocation references or tenant ownership are invalid on % rows; no data was changed',mismatch_count; end if;

    execute 'update public.supplier_payment_allocations set organization_id=org_id,supplier_payment_id=payment_id where organization_id is null or supplier_payment_id is null';
  else
    select count(*) into mismatch_count from public.supplier_payment_allocations
    where organization_id is null or supplier_payment_id is null;
    if mismatch_count>0 then raise exception 'Canonical supplier allocation ownership is missing on % rows',mismatch_count; end if;
  end if;

  select count(*) into mismatch_count
  from (
    select organization_id,supplier_payment_id,purchase_id from public.supplier_payment_allocations
    group by organization_id,supplier_payment_id,purchase_id having count(*)>1
  ) duplicates;
  if mismatch_count>0 then raise exception 'Duplicate supplier payment/purchase allocations exist on % key(s)',mismatch_count; end if;

  select count(*) into mismatch_count
  from (select supplier_payment_id,sum(amount) as allocated from public.supplier_payment_allocations group by supplier_payment_id) a
  join public.supplier_payments sp on sp.id=a.supplier_payment_id
  where a.allocated>sp.amount;
  if mismatch_count>0 then raise exception 'Supplier payment allocations exceed payment amount on % payments',mismatch_count; end if;

  select count(*) into mismatch_count
  from (select purchase_id,sum(amount) as allocated from public.supplier_payment_allocations group by purchase_id) a
  join public.purchases p on p.id=a.purchase_id
  where a.allocated>p.total_amount;
  if mismatch_count>0 then raise exception 'Supplier payment allocations exceed purchase total on % purchases',mismatch_count; end if;
end;
$$;

alter table public.supplier_payment_allocations
  alter column organization_id set not null,
  alter column supplier_payment_id set not null;

-- Keep old required aliases and new canonical columns in sync for legacy callers.
create or replace function public.sync_supplier_payment_allocation_columns()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  row_json jsonb;
  org_value uuid;
  payment_value uuid;
begin
  row_json := to_jsonb(new);
  org_value := coalesce(nullif(row_json->>'organization_id','')::uuid,nullif(row_json->>'org_id','')::uuid);
  payment_value := coalesce(nullif(row_json->>'supplier_payment_id','')::uuid,nullif(row_json->>'payment_id','')::uuid);
  if org_value is null or payment_value is null then
    raise exception 'Supplier allocation requires organization and supplier payment references';
  end if;
  if row_json ? 'org_id' and row_json->>'org_id' is not null
     and (row_json->>'org_id')::uuid<>org_value then
    raise exception 'Legacy org_id conflicts with organization_id';
  end if;
  if row_json ? 'payment_id' and row_json->>'payment_id' is not null
     and (row_json->>'payment_id')::uuid<>payment_value then
    raise exception 'Legacy payment_id conflicts with supplier_payment_id';
  end if;
  row_json := jsonb_set(row_json,'{organization_id}',to_jsonb(org_value),true);
  row_json := jsonb_set(row_json,'{supplier_payment_id}',to_jsonb(payment_value),true);
  if row_json ? 'org_id' then row_json := jsonb_set(row_json,'{org_id}',to_jsonb(org_value),true); end if;
  if row_json ? 'payment_id' then row_json := jsonb_set(row_json,'{payment_id}',to_jsonb(payment_value),true); end if;
  new := jsonb_populate_record(new,row_json);
  return new;
end;
$$;
drop trigger if exists supplier_payment_allocation_compat_sync on public.supplier_payment_allocations;
create trigger supplier_payment_allocation_compat_sync
  before insert or update on public.supplier_payment_allocations
  for each row execute function public.sync_supplier_payment_allocation_columns();

create unique index if not exists supplier_payment_allocations_org_payment_purchase_uidx
  on public.supplier_payment_allocations(organization_id,supplier_payment_id,purchase_id);
create index if not exists supplier_payment_allocations_org_purchase_idx
  on public.supplier_payment_allocations(organization_id,purchase_id);

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
end;
$$;
alter table public.supplier_payment_allocations validate constraint supplier_allocations_org_payment_fk;
alter table public.supplier_payment_allocations validate constraint supplier_allocations_org_purchase_fk;

-- The older permissive tenant policy uses org_id. The sync trigger keeps that
-- field equal to organization_id; this restrictive policy adds role and plan gates.
drop policy if exists supplier_payment_allocations_plan_read on public.supplier_payment_allocations;
create policy supplier_payment_allocations_plan_read on public.supplier_payment_allocations
  as restrictive for select to authenticated
  using (public.has_org_permission(organization_id,'purchases','view')
    and public.organization_has_plan_feature(organization_id,'supplier_payables'));

-- Replace the older payment writer with the validated allocation-aware RPC.
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

  perform pg_advisory_xact_lock(hashtextextended(p_org_id::text||':supplier_payment:'||p_idempotency_key,0));
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

  select s.opening_balance into v_supplier_opening from public.suppliers s
    where s.id=p_supplier_id and s.organization_id=p_org_id for update;
  select greatest(coalesce(v_supplier_opening,0)
      + coalesce((select sum(p.total_amount) from public.purchases p
        where p.organization_id=p_org_id and p.supplier_id=p_supplier_id and p.status='received'),0)
      - coalesce((select sum(sp.amount) from public.supplier_payments sp
        where sp.organization_id=p_org_id and sp.supplier_id=p_supplier_id),0),0)
    into v_supplier_due;
  if v_total_allocated>v_supplier_due then raise exception 'Allocated payment exceeds supplier payable balance after existing advances'; end if;

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
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by value->>'purchase_id' loop
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
