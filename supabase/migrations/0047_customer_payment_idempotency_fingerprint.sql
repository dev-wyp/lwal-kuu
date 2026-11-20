-- Bind customer-payment retries to their complete normalized request. Existing
-- payment rows are preserved; the new fingerprint is nullable for legacy rows.
begin;

-- Verify the additive migration contract before defining the replacement RPC.
-- Fail with the mismatched columns rather than guessing at a drifted ledger.
do $$
declare
  incompatible_columns text[];
  fingerprint_type text;
begin
  select array_agg(required.table_name||'.'||required.column_name||
      ' (expected '||required.expected_udt_name||', found '||coalesce(c.udt_name,'missing')||')'
      order by required.table_name,required.column_name)
    into incompatible_columns
  from (values
    ('payments','id','uuid'),('payments','organization_id','uuid'),('payments','customer_id','uuid'),
    ('payments','payment_number','text'),('payments','amount','numeric'),
    ('payments','allocated_amount','numeric'),('payments','payment_method','text'),
    ('payments','payment_date','date'),('payments','reference_number','text'),('payments','notes','text'),
    ('payments','status','text'),('payments','idempotency_key','text'),('payments','created_by','uuid'),
    ('payment_allocations','organization_id','uuid'),('payment_allocations','payment_id','uuid'),
    ('payment_allocations','sale_id','uuid'),('payment_allocations','allocated_amount','numeric'),
    ('sales','id','uuid'),('sales','organization_id','uuid'),('sales','customer_id','uuid'),
    ('sales','status','text'),('sales','total_amount','numeric'),('sales','paid_amount','numeric'),
    ('sales','payment_status','text'),('sales','updated_at','timestamptz')
  ) as required(table_name,column_name,expected_udt_name)
  left join information_schema.columns c
    on c.table_schema='public' and c.table_name=required.table_name
   and c.column_name=required.column_name
  where c.column_name is null or c.udt_name<>required.expected_udt_name;

  select c.udt_name into fingerprint_type
  from information_schema.columns c
  where c.table_schema='public' and c.table_name='payments'
    and c.column_name='request_fingerprint';
  if incompatible_columns is not null or (fingerprint_type is not null and fingerprint_type<>'text') then
    raise exception 'Customer payment fingerprint migration is incompatible with the existing schema. Mismatched columns: %; request_fingerprint type: %. Inspect the payment schema before retrying.',
      coalesce(array_to_string(incompatible_columns,', '),'none'),coalesce(fingerprint_type,'not present');
  end if;
end;
$$;

alter table public.payments
  add column if not exists request_fingerprint text;

create or replace function public.record_customer_payment_and_allocate(
  p_org_id uuid,
  p_customer_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_allocations jsonb,
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
  v_payment public.payments%rowtype;
  v_sale public.sales%rowtype;
  v_alloc jsonb;
  v_sale_id uuid;
  v_alloc_amt numeric(14,2);
  v_total_allocated numeric(14,2) := 0;
  v_amount numeric(14,2);
  v_payment_num text;
  v_payment_id uuid;
  v_fingerprint text;
  v_normalized_allocations jsonb;
  v_existing_allocations jsonb;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'customers','update') then raise exception 'Unauthorized'; end if;
  if p_amount is null or p_amount <= 0 or p_amount::text in ('NaN','Infinity','-Infinity') then
    raise exception 'Payment amount must be a finite number greater than zero';
  end if;
  v_amount := round(p_amount,2);
  if v_amount<=0 then raise exception 'Payment amount is below the supported currency precision'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then
    raise exception 'Unsupported payment method';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then
    raise exception 'A valid idempotency key is required';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'Allocations must be a JSON array';
  end if;
  if not exists(select 1 from public.customers c where c.id=p_customer_id and c.organization_id=p_org_id and c.is_active) then
    raise exception 'Customer does not belong to this organization or is inactive';
  end if;

  -- Validate and canonicalize the whole request before looking up a retry key.
  -- Sorting by UUID makes equivalent allocation arrays fingerprint identically.
  if exists(select 1 from jsonb_array_elements(p_allocations) x(value)
      group by (value->>'sale_id') having count(*)>1) then
    raise exception 'Duplicate invoice allocation';
  end if;
  for v_alloc in select value from jsonb_array_elements(p_allocations) loop
    if jsonb_typeof(v_alloc)<>'object'
       or nullif(v_alloc->>'sale_id','') is null
       or nullif(v_alloc->>'amount','') is null then
      raise exception 'Each allocation needs a sale_id and amount';
    end if;
    v_sale_id := (v_alloc->>'sale_id')::uuid;
    if (v_alloc->>'amount')::numeric::text in ('NaN','Infinity','-Infinity') then
      raise exception 'Allocation amount must be a finite number';
    end if;
    v_alloc_amt := round((v_alloc->>'amount')::numeric,2);
    if v_alloc_amt<=0 then
      raise exception 'Allocation amount must be greater than zero at supported currency precision';
    end if;
    v_total_allocated := v_total_allocated+v_alloc_amt;
  end loop;
  if v_total_allocated>v_amount then raise exception 'Allocations cannot exceed the payment amount'; end if;

  if exists (
    select 1 from (
      select (value->>'sale_id')::uuid as sale_id
      from jsonb_array_elements(p_allocations) x(value)
    ) normalized group by sale_id having count(*)>1
  ) then
    raise exception 'Duplicate invoice allocation';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'sale_id',(value->>'sale_id')::uuid,
      'amount',round((value->>'amount')::numeric,2)
    ) order by (value->>'sale_id')::uuid),'[]'::jsonb)
    into v_normalized_allocations
  from jsonb_array_elements(p_allocations) x(value);

  v_fingerprint := md5(jsonb_build_object(
    'organization_id',p_org_id,
    'customer_id',p_customer_id,
    'amount',v_amount,
    'payment_method',p_payment_method,
    'reference_number',p_reference_number,
    'notes',p_notes,
    'allocations',v_normalized_allocations
  )::text);

  -- Serialize same-key requests so concurrent retries observe and return the
  -- first committed result instead of racing into a unique-index error.
  perform pg_advisory_xact_lock(hashtextextended(p_org_id::text||':customer_payment:'||p_idempotency_key,0));
  select * into v_payment from public.payments p
  where p.organization_id=p_org_id and p.idempotency_key=p_idempotency_key for update;
  if found then
    if v_payment.request_fingerprint is not null then
      if v_payment.request_fingerprint<>v_fingerprint then
        raise exception 'Idempotency key was already used for a different payment request';
      end if;
    else
      -- Preserve safe retries for pre-migration rows by comparing their stored
      -- values and allocations. If history does not match, fail closed.
      select coalesce(jsonb_agg(jsonb_build_object(
          'sale_id',pa.sale_id,
          'amount',round(pa.allocated_amount,2)
        ) order by pa.sale_id),'[]'::jsonb)
        into v_existing_allocations
      from public.payment_allocations pa
      where pa.organization_id=p_org_id and pa.payment_id=v_payment.id;
      if v_payment.customer_id is distinct from p_customer_id
         or v_payment.amount is distinct from v_amount
         or v_payment.payment_method is distinct from p_payment_method
         or v_payment.reference_number is distinct from p_reference_number
         or v_payment.notes is distinct from p_notes
         or v_existing_allocations is distinct from v_normalized_allocations then
        raise exception 'Idempotency key was already used for a different payment request';
      end if;
    end if;
    return jsonb_build_object('success',true,'payment_id',v_payment.id,'payment_number',v_payment.payment_number,
      'allocated_amount',v_payment.allocated_amount,'unallocated_amount',v_payment.amount-v_payment.allocated_amount);
  end if;

  v_payment_num := public.next_document_number(p_org_id,'customer_payment');
  insert into public.payments(organization_id,customer_id,payment_number,payment_date,amount,
    allocated_amount,payment_method,reference_number,notes,status,idempotency_key,request_fingerprint,created_by)
  values(p_org_id,p_customer_id,v_payment_num,current_date,v_amount,0,p_payment_method,
    p_reference_number,p_notes,'posted',p_idempotency_key,v_fingerprint,v_user_id)
  returning id into v_payment_id;

  -- UUID order ensures concurrent multi-invoice requests acquire locks consistently.
  for v_alloc in select value from jsonb_array_elements(v_normalized_allocations)
      order by (value->>'sale_id')::uuid loop
    v_sale_id := (v_alloc->>'sale_id')::uuid;
    v_alloc_amt := (v_alloc->>'amount')::numeric(14,2);
    select * into v_sale from public.sales s
      where s.id=v_sale_id and s.organization_id=p_org_id for update;
    if not found then raise exception 'Invoice does not belong to this organization'; end if;
    if v_sale.status<>'confirmed' then raise exception 'Only confirmed invoices can receive allocations'; end if;
    if v_sale.customer_id is distinct from p_customer_id then raise exception 'Invoice belongs to another customer'; end if;
    if v_alloc_amt>greatest(v_sale.total_amount-v_sale.paid_amount,0) then raise exception 'Allocation exceeds invoice outstanding balance'; end if;
    insert into public.payment_allocations(organization_id,payment_id,sale_id,allocated_amount)
      values(p_org_id,v_payment_id,v_sale_id,v_alloc_amt);
    update public.sales set paid_amount=paid_amount+v_alloc_amt,
      payment_status=case when paid_amount+v_alloc_amt>=total_amount then 'paid' else 'partial' end,
      updated_at=now()
      where id=v_sale_id and organization_id=p_org_id;
  end loop;
  update public.payments set allocated_amount=v_total_allocated where id=v_payment_id and organization_id=p_org_id;
  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(p_org_id,v_user_id,'customer_payment.create','payment',v_payment_id,
    jsonb_build_object('payment_number',v_payment_num,'amount',v_amount,'allocated_amount',v_total_allocated,
      'idempotency_key',p_idempotency_key));
  return jsonb_build_object('success',true,'payment_id',v_payment_id,'payment_number',v_payment_num,
    'allocated_amount',v_total_allocated,'unallocated_amount',v_amount-v_total_allocated);
end;
$$;

revoke all on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) from public,anon;
grant execute on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) to authenticated;

notify pgrst,'reload schema';
commit;
