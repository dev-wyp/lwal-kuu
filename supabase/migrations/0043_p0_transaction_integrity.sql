-- P0 transaction and tenant-integrity hardening.
-- This migration is incremental and does not modify production by itself.
-- Composite FKs are added NOT VALID: new writes are protected immediately while
-- existing rows remain unvalidated until an operator reviews mismatch counts.

begin;

-- A globally unique id also makes (organization_id,id) unique. These indexes are
-- referenced by tenant-aware composite foreign keys below.
create unique index if not exists products_org_id_uidx on public.products(organization_id,id);
create unique index if not exists product_categories_org_id_uidx on public.product_categories(organization_id,id);
create unique index if not exists units_org_id_uidx on public.units(organization_id,id);
create unique index if not exists suppliers_org_id_uidx on public.suppliers(organization_id,id);
create unique index if not exists branches_org_id_uidx on public.branches(organization_id,id);
create unique index if not exists purchases_org_id_uidx on public.purchases(organization_id,id);
create unique index if not exists sales_org_id_uidx on public.sales(organization_id,id);
create unique index if not exists customers_org_id_uidx on public.customers(organization_id,id);
create unique index if not exists payments_org_id_uidx on public.payments(organization_id,id);
create unique index if not exists stock_transfers_org_id_uidx on public.stock_transfers(organization_id,id);

-- Preserve legacy cross-tenant rows for remediation while enforcing ownership on
-- all future insert/update operations. Optional references that need column-specific
-- SET NULL semantics remain validated by the RPCs until an explicit migration plan.
do $$
declare
  rel record;
  child_oid regclass;
  parent_oid regclass;
begin
  for rel in
    select * from (values
      ('products','unit_id','units','id','products_org_unit_fk'),
      ('purchases','supplier_id','suppliers','id','purchases_org_supplier_fk'),
      ('purchases','branch_id','branches','id','purchases_org_branch_fk'),
      ('purchase_items','purchase_id','purchases','id','purchase_items_org_purchase_fk'),
      ('purchase_items','product_id','products','id','purchase_items_org_product_fk'),
      ('supplier_payments','supplier_id','suppliers','id','supplier_payments_org_supplier_fk'),
      ('sales','customer_id','customers','id','sales_org_customer_fk'),
      ('sales','branch_id','branches','id','sales_org_branch_fk'),
      ('sale_items','sale_id','sales','id','sale_items_org_sale_fk'),
      ('sale_items','product_id','products','id','sale_items_org_product_fk'),
      ('payments','customer_id','customers','id','payments_org_customer_fk'),
      ('payment_allocations','payment_id','payments','id','payment_allocations_org_payment_fk'),
      ('payment_allocations','sale_id','sales','id','payment_allocations_org_sale_fk'),
      ('stock_adjustments','product_id','products','id','stock_adjustments_org_product_fk'),
      ('stock_adjustments','branch_id','branches','id','stock_adjustments_org_branch_fk'),
      ('stock_movements','product_id','products','id','stock_movements_org_product_fk'),
      ('stock_movements','branch_id','branches','id','stock_movements_org_branch_fk'),
      ('stock_transfers','source_branch_id','branches','id','stock_transfers_org_source_branch_fk'),
      ('stock_transfers','destination_branch_id','branches','id','stock_transfers_org_destination_branch_fk'),
      ('stock_transfer_items','transfer_id','stock_transfers','id','stock_transfer_items_org_transfer_fk'),
      ('stock_transfer_items','product_id','products','id','stock_transfer_items_org_product_fk')
    ) as relationships(child_table, child_key, parent_table, parent_key, constraint_name)
  loop
    child_oid := to_regclass(format('public.%I', rel.child_table));
    parent_oid := to_regclass(format('public.%I', rel.parent_table));
    if child_oid is null or parent_oid is null then
      raise exception 'Required table for tenant FK %.% -> %.% is missing', rel.child_table, rel.child_key, rel.parent_table, rel.parent_key;
    end if;
    if not exists (select 1 from pg_constraint where conrelid=child_oid and conname=rel.constraint_name) then
      execute format(
        'alter table %s add constraint %I foreign key (organization_id,%I) references %s (organization_id,%I) not valid',
        child_oid, rel.constraint_name, rel.child_key, parent_oid, rel.parent_key
      );
    end if;
  end loop;
end;
$$;

-- Replace unsafe globally unique request-key constraints with organization-scoped
-- uniqueness. Existing values cannot collide across organizations while the old
-- global constraint exists; a pre-deployment catalog/data check is still required.
create unique index if not exists sales_org_idempotency_key_uidx
  on public.sales(organization_id,idempotency_key) where idempotency_key is not null;
create unique index if not exists payments_org_idempotency_key_uidx
  on public.payments(organization_id,idempotency_key) where idempotency_key is not null;
alter table public.sales drop constraint if exists sales_idempotency_key_key;
alter table public.payments drop constraint if exists payments_idempotency_key_key;

-- Remove the blanket authenticated SELECT allowance from organization settings.
drop policy if exists "Members can view organization settings" on public.organization_settings;
create policy "Members can view organization settings"
  on public.organization_settings for select to authenticated
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create or replace function public.confirm_sale(
  p_org_id uuid,
  p_sale_id uuid,
  p_payment_method text default 'cash',
  p_amount_paid numeric default 0.00,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_sale public.sales%rowtype;
  v_product public.products%rowtype;
  v_item record;
  v_requested numeric(14,2);
  v_available numeric(14,2);
  v_subtotal numeric(14,2) := 0;
  v_line_discount numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_total_cost numeric(14,2) := 0;
  v_paid numeric(14,2) := coalesce(p_amount_paid,0);
  v_pay_status text;
  v_payment_id uuid;
  v_payment_num text;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'sales','create') then raise exception 'Unauthorized'; end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then
    raise exception 'A valid idempotency key is required';
  end if;
  if v_paid < 0 then raise exception 'Payment amount cannot be negative'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then
    raise exception 'Unsupported payment method';
  end if;

  -- Retries are scoped to this organization and must refer to this exact sale.
  select * into v_sale from public.sales
  where organization_id=p_org_id and idempotency_key=p_idempotency_key;
  if found then
    if v_sale.id <> p_sale_id then raise exception 'Idempotency key was already used for another sale'; end if;
    if v_sale.status = 'confirmed' then
      return jsonb_build_object('success',true,'sale_id',v_sale.id,'invoice_number',v_sale.invoice_number,
        'payment_status',v_sale.payment_status,'sale',to_jsonb(v_sale),
        'items',(select coalesce(jsonb_agg(to_jsonb(si) order by si.created_at,si.id),'[]'::jsonb)
                 from public.sale_items si where si.organization_id=p_org_id and si.sale_id=v_sale.id));
    end if;
  end if;

  select * into v_sale from public.sales
  where id=p_sale_id and organization_id=p_org_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if v_sale.status <> 'draft' then raise exception 'Only draft sales can be confirmed'; end if;
  if v_sale.branch_id is null or not exists (
    select 1 from public.branches b where b.id=v_sale.branch_id and b.organization_id=p_org_id and b.is_active
  ) then raise exception 'Sale must use an active branch in this organization'; end if;
  if v_sale.customer_id is not null and not exists (
    select 1 from public.customers c where c.id=v_sale.customer_id and c.organization_id=p_org_id and c.is_active
  ) then raise exception 'Sale customer does not belong to this organization or is inactive'; end if;
  if coalesce(v_sale.tax_amount,0) <> 0 then
    raise exception 'Tax cannot be posted until an organization tax rule is configured';
  end if;

  if not exists (select 1 from public.sale_items si where si.sale_id=p_sale_id and si.organization_id=p_org_id) then
    raise exception 'Sale requires at least one item';
  end if;
  if exists (select 1 from public.sale_items si where si.sale_id=p_sale_id and si.organization_id<>p_org_id) then
    raise exception 'Sale contains a line from another organization';
  end if;

  -- Lock product rows in a stable order before checking branch stock. The same
  -- organization/branch/product advisory key is used by the branch stock trigger.
  for v_item in
    select si.product_id, sum(si.quantity)::numeric(14,2) as requested_quantity
    from public.sale_items si
    where si.sale_id=p_sale_id and si.organization_id=p_org_id
    group by si.product_id order by si.product_id
  loop
    select * into v_product from public.products p
    where p.id=v_item.product_id and p.organization_id=p_org_id and p.is_active
    for update;
    if not found then raise exception 'Sale product is missing, inactive, or belongs to another organization'; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_org_id::text || ':' || v_sale.branch_id::text || ':' || v_product.id::text,0));
    select coalesce(sum(sm.quantity),0) into v_available from public.stock_movements sm
    where sm.organization_id=p_org_id and sm.branch_id=v_sale.branch_id and sm.product_id=v_product.id;
    if v_available < v_item.requested_quantity then
      raise exception 'Insufficient stock for product % (available %, requested %)',v_product.name,v_available,v_item.requested_quantity;
    end if;
  end loop;

  -- Catalog price is authoritative in the current POS (which has no price override
  -- approval flow). Recompute every line and the header instead of trusting totals.
  for v_item in
    select si.* from public.sale_items si
    where si.sale_id=p_sale_id and si.organization_id=p_org_id order by si.product_id,si.id
    for update
  loop
    select * into v_product from public.products p
    where p.id=v_item.product_id and p.organization_id=p_org_id and p.is_active;
    if not found then raise exception 'Sale product is missing, inactive, or belongs to another organization'; end if;
    if v_item.quantity <= 0 then raise exception 'Sale quantity must be positive'; end if;
    if v_item.unit_price <> v_product.sale_price then raise exception 'Sale price differs from the current approved product price'; end if;
    if v_item.discount_amount < 0 or v_item.discount_amount > (v_item.quantity * v_item.unit_price) then
      raise exception 'Sale line discount is outside the allowed range';
    end if;
    update public.sale_items set unit_cost=v_product.average_cost,
      total_amount=round(v_item.quantity*v_item.unit_price-v_item.discount_amount,2)
    where id=v_item.id and organization_id=p_org_id;
    v_subtotal := v_subtotal + round(v_item.quantity*v_item.unit_price,2);
    v_line_discount := v_line_discount + v_item.discount_amount;
    v_total_cost := v_total_cost + (v_item.quantity*v_product.average_cost);
  end loop;

  if v_sale.discount_amount < 0 or v_sale.discount_amount + v_line_discount > v_subtotal then
    raise exception 'Sale discount exceeds the item subtotal';
  end if;
  v_total := round(v_subtotal-v_line_discount-v_sale.discount_amount,2);
  if v_paid > v_total then raise exception 'Received payment cannot exceed the sale total'; end if;
  if v_sale.customer_id is null and v_paid < v_total then
    raise exception 'A customer is required for a credit or partially paid sale';
  end if;
  v_pay_status := case when v_paid >= v_total then 'paid' when v_paid > 0 then 'partial' else 'unpaid' end;

  update public.sales set subtotal=v_subtotal,total=v_total,total_amount=v_total,
    status='confirmed',total_cost=round(v_total_cost,2),paid_amount=v_paid,
    payment_status=v_pay_status,idempotency_key=p_idempotency_key,updated_at=now()
  where id=p_sale_id and organization_id=p_org_id;

  if v_paid > 0 then
    v_payment_num := public.next_document_number(p_org_id,'customer_payment');
    insert into public.payments(organization_id,customer_id,payment_number,payment_date,
      amount,allocated_amount,payment_method,status,idempotency_key,created_by)
    values(p_org_id,v_sale.customer_id,v_payment_num,current_date,v_paid,v_paid,p_payment_method,
      'posted','sale:'||p_idempotency_key,v_user_id)
    returning id into v_payment_id;
    insert into public.payment_allocations(organization_id,payment_id,sale_id,allocated_amount)
    values(p_org_id,v_payment_id,p_sale_id,v_paid);
  end if;

  for v_item in
    select si.product_id, sum(si.quantity)::numeric(14,2) as quantity,
      max(si.unit_cost)::numeric(14,4) as unit_cost
    from public.sale_items si where si.sale_id=p_sale_id and si.organization_id=p_org_id
    group by si.product_id order by si.product_id
  loop
    insert into public.stock_movements(organization_id,branch_id,product_id,movement_type,
      quantity,unit_cost,reference_type,reference_id,created_by)
    values(p_org_id,v_sale.branch_id,v_item.product_id,'sales_out',-v_item.quantity,
      v_item.unit_cost,'sale',p_sale_id,v_user_id);
  end loop;

  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(p_org_id,v_user_id,'sale.confirm','sale',p_sale_id,
    jsonb_build_object('invoice_number',v_sale.invoice_number,'total',v_total,'paid',v_paid,'idempotency_key',p_idempotency_key));
  select * into v_sale from public.sales where id=p_sale_id and organization_id=p_org_id;
  return jsonb_build_object('success',true,'sale_id',p_sale_id,'invoice_number',v_sale.invoice_number,
    'payment_status',v_pay_status,'sale',to_jsonb(v_sale),
    'items',(select coalesce(jsonb_agg(to_jsonb(si) order by si.created_at,si.id),'[]'::jsonb)
             from public.sale_items si where si.organization_id=p_org_id and si.sale_id=p_sale_id));
end;
$$;

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
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'customers','update') then raise exception 'Unauthorized'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  v_amount := round(p_amount,2);
  if v_amount<=0 then raise exception 'Payment amount is below the supported currency precision'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then raise exception 'Unsupported payment method'; end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then raise exception 'A valid idempotency key is required'; end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then raise exception 'Allocations must be a JSON array'; end if;
  if not exists(select 1 from public.customers c where c.id=p_customer_id and c.organization_id=p_org_id and c.is_active) then
    raise exception 'Customer does not belong to this organization or is inactive';
  end if;

  select * into v_payment from public.payments p
  where p.organization_id=p_org_id and p.idempotency_key=p_idempotency_key for update;
  if found then
    if v_payment.customer_id is distinct from p_customer_id or v_payment.amount<>v_amount or v_payment.payment_method<>p_payment_method then
      raise exception 'Idempotency key was already used for a different payment';
    end if;
    return jsonb_build_object('success',true,'payment_id',v_payment.id,'payment_number',v_payment.payment_number,
      'allocated_amount',v_payment.allocated_amount,'unallocated_amount',v_payment.amount-v_payment.allocated_amount);
  end if;

  if exists(select 1 from jsonb_array_elements(p_allocations) x(value)
    group by value->>'sale_id' having count(*)>1) then raise exception 'Duplicate invoice allocation'; end if;
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by value->>'sale_id' loop
    if jsonb_typeof(v_alloc)<>'object' or nullif(v_alloc->>'sale_id','') is null or nullif(v_alloc->>'amount','') is null then
      raise exception 'Each allocation needs a sale_id and amount';
    end if;
    v_alloc_amt := (v_alloc->>'amount')::numeric(14,2);
    if v_alloc_amt<=0 then raise exception 'Allocation amount must be greater than zero at supported currency precision'; end if;
    v_total_allocated := v_total_allocated+v_alloc_amt;
  end loop;
  if v_total_allocated>v_amount then raise exception 'Allocations cannot exceed the payment amount'; end if;

  v_payment_num := public.next_document_number(p_org_id,'customer_payment');
  insert into public.payments(organization_id,customer_id,payment_number,payment_date,amount,
    allocated_amount,payment_method,reference_number,notes,status,idempotency_key,created_by)
  values(p_org_id,p_customer_id,v_payment_num,current_date,v_amount,0,p_payment_method,
    p_reference_number,p_notes,'posted',p_idempotency_key,v_user_id)
  returning id into v_payment_id;

  -- UUID lexical order gives every concurrent multi-invoice payment the same lock order.
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by (value->>'sale_id')::uuid loop
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
    jsonb_build_object('payment_number',v_payment_num,'amount',p_amount,'allocated_amount',v_total_allocated,'idempotency_key',p_idempotency_key));
  return jsonb_build_object('success',true,'payment_id',v_payment_id,'payment_number',v_payment_num,
    'allocated_amount',v_total_allocated,'unallocated_amount',v_amount-v_total_allocated);
end;
$$;

-- Secure the existing one-shot receiving API. This preserves its signature for
-- current clients, but now receives only the unreceived remainder of each line and
-- rejects replay once the purchase is fully received. A separate partial-GRN UI/API
-- is a planned follow-on; callers of this compatible RPC receive all remaining units.
create or replace function public.receive_purchase(
  p_org_id uuid,
  p_purchase_id uuid,
  p_amount_paid numeric default 0.00,
  p_payment_method text default 'cash'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_purchase public.purchases%rowtype;
  v_product public.products%rowtype;
  v_item record;
  v_remaining numeric(14,2);
  v_stock numeric(14,2);
  v_new_avg_cost numeric(14,4);
  v_paid numeric(14,2) := coalesce(p_amount_paid,0);
  v_payment_number text;
  v_outstanding numeric(14,2);
  v_subtotal numeric(14,2);
  v_total numeric(14,2);
  v_supplier_id uuid;
  v_receipt_count integer := 0;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'purchases','update') then raise exception 'Unauthorized'; end if;
  if v_paid<0 then raise exception 'Payment amount cannot be negative'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then raise exception 'Unsupported payment method'; end if;

  select supplier_id into v_supplier_id from public.purchases
    where id=p_purchase_id and organization_id=p_org_id;
  if not found then raise exception 'Purchase order not found'; end if;
  perform 1 from public.suppliers s
    where s.id=v_supplier_id and s.organization_id=p_org_id for update;
  if not found then raise exception 'Purchase supplier does not belong to this organization'; end if;
  select * into v_purchase from public.purchases
    where id=p_purchase_id and organization_id=p_org_id for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if v_purchase.supplier_id<>v_supplier_id then raise exception 'Purchase supplier changed during receiving; retry the operation'; end if;
  if v_purchase.status in ('received','voided') then raise exception 'Purchase cannot be received in its current status'; end if;
  if not exists(select 1 from public.suppliers s where s.id=v_purchase.supplier_id and s.organization_id=p_org_id and s.is_active) then
    raise exception 'Purchase supplier does not belong to this organization or is inactive';
  end if;
  if v_purchase.branch_id is null or not exists(select 1 from public.branches b where b.id=v_purchase.branch_id and b.organization_id=p_org_id and b.is_active) then
    raise exception 'Purchase must use an active branch in this organization';
  end if;
  if not exists(select 1 from public.purchase_items pi where pi.purchase_id=p_purchase_id and pi.organization_id=p_org_id and pi.quantity>pi.received_quantity) then
    raise exception 'Purchase has no outstanding quantities to receive';
  end if;
  if exists(select 1 from public.purchase_items pi where pi.purchase_id=p_purchase_id and pi.organization_id<>p_org_id) then
    raise exception 'Purchase contains a line from another organization';
  end if;
  if coalesce(v_purchase.tax_amount,0)<>0 then raise exception 'Purchase tax cannot be posted until an organization tax rule is configured'; end if;
  select coalesce(sum(round(pi.quantity*pi.unit_cost,2)),0)::numeric(14,2)
    into v_subtotal from public.purchase_items pi
    where pi.purchase_id=p_purchase_id and pi.organization_id=p_org_id;
  if v_purchase.discount_amount<0 or v_purchase.discount_amount>v_subtotal then raise exception 'Purchase discount exceeds item subtotal'; end if;
  v_total := round(v_subtotal-v_purchase.discount_amount,2);
  update public.purchases set subtotal=v_subtotal,total=v_total,total_amount=v_total
    where id=p_purchase_id and organization_id=p_org_id;

  v_outstanding := greatest(v_total-coalesce(v_purchase.paid_amount,0),0);
  if v_paid>v_outstanding then raise exception 'Supplier payment exceeds purchase outstanding balance'; end if;
  -- Starter supports cash purchases. Supplier-payables is required only when
  -- receipt leaves an amount outstanding that must be tracked and paid later.
  if v_paid>0 and v_paid<v_outstanding
      and not public.organization_has_plan_feature(p_org_id,'supplier_payables') then
    raise exception 'Partial supplier payments are not available on the current plan';
  end if;

  for v_item in select pi.id,pi.product_id,pi.quantity,pi.received_quantity,pi.unit_cost
    from public.purchase_items pi where pi.purchase_id=p_purchase_id and pi.organization_id=p_org_id
      and pi.quantity>pi.received_quantity order by pi.product_id,pi.id for update
  loop
    select * into v_product from public.products p
      where p.id=v_item.product_id and p.organization_id=p_org_id and p.is_active for update;
    if not found then raise exception 'Purchase product is missing, inactive, or belongs to another organization'; end if;
    v_remaining := v_item.quantity-v_item.received_quantity;
    if v_remaining<=0 or v_item.unit_cost<0 then raise exception 'Purchase line has invalid outstanding quantity or cost'; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_org_id::text||':'||v_purchase.branch_id::text||':'||v_product.id::text,0));
    select coalesce(sum(sm.quantity),0) into v_stock from public.stock_movements sm
      where sm.organization_id=p_org_id and sm.product_id=v_product.id;
    if v_stock>0 then
      v_new_avg_cost := ((v_stock*v_product.average_cost)+(v_remaining*v_item.unit_cost))/(v_stock+v_remaining);
    else
      v_new_avg_cost := v_item.unit_cost;
    end if;
    update public.products set average_cost=v_new_avg_cost,purchase_price=v_item.unit_cost,updated_at=now()
      where id=v_product.id and organization_id=p_org_id;
    insert into public.stock_movements(organization_id,branch_id,product_id,movement_type,quantity,
      unit_cost,reference_type,reference_id,created_by)
      values(p_org_id,v_purchase.branch_id,v_product.id,'purchase_in',v_remaining,v_item.unit_cost,'purchase',p_purchase_id,v_user_id);
    update public.purchase_items set received_quantity=quantity,total_cost=round(quantity*unit_cost,2)
      where id=v_item.id and organization_id=p_org_id;
    v_receipt_count := v_receipt_count+1;
  end loop;

  if v_paid>0 then
    v_payment_number := public.next_document_number(p_org_id,'supplier_payment');
    insert into public.supplier_payments(organization_id,supplier_id,purchase_id,payment_number,
      payment_date,amount,payment_method,created_by)
      values(p_org_id,v_purchase.supplier_id,p_purchase_id,v_payment_number,current_date,v_paid,p_payment_method,v_user_id);
  end if;
  update public.purchases set status='received',paid_amount=coalesce(paid_amount,0)+v_paid,updated_at=now()
    where id=p_purchase_id and organization_id=p_org_id;
  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
    values(p_org_id,v_user_id,'purchase.receive','purchase',p_purchase_id,
      jsonb_build_object('receipt_line_count',v_receipt_count,'payment_amount',v_paid));
  return jsonb_build_object('success',true,'purchase_id',p_purchase_id,'status','received','received_line_count',v_receipt_count);
end;
$$;

-- Revoke direct client execution of global worker jobs. Guarded platform-admin
-- actions retain authenticated access; scheduled jobs and edge workers use service_role.
revoke all on function public.cron_check_expired_subscriptions() from public,anon,authenticated;
revoke all on function public.cron_queue_daily_sales_summaries() from public,anon,authenticated;
revoke all on function public.cron_queue_low_stock_alerts() from public,anon,authenticated;
revoke all on function public.cron_queue_subscription_renewal_reminders() from public,anon,authenticated;
revoke all on function public.cron_queue_weekly_business_summary() from public,anon,authenticated;
revoke all on function public.cron_detect_expired_social_connections() from public,anon,authenticated;
revoke all on function public.cron_notify_upcoming_scheduled_posts() from public,anon,authenticated;
grant execute on function public.cron_check_expired_subscriptions() to service_role;
grant execute on function public.cron_queue_daily_sales_summaries() to service_role;
grant execute on function public.cron_queue_low_stock_alerts() to service_role;
grant execute on function public.cron_queue_subscription_renewal_reminders() to service_role;
grant execute on function public.cron_queue_weekly_business_summary() to service_role;
grant execute on function public.cron_detect_expired_social_connections() to service_role;
grant execute on function public.cron_notify_upcoming_scheduled_posts() to service_role;

revoke all on function public.cron_run_all_automations() from public,anon;
grant execute on function public.cron_run_all_automations() to authenticated,service_role;
revoke all on function public.cron_queue_debt_reminders() from public,anon;
grant execute on function public.cron_queue_debt_reminders() to authenticated,service_role;

revoke all on function public.confirm_sale(uuid,uuid,text,numeric,text) from public,anon;
grant execute on function public.confirm_sale(uuid,uuid,text,numeric,text) to authenticated;
revoke all on function public.receive_purchase(uuid,uuid,numeric,text) from public,anon;
grant execute on function public.receive_purchase(uuid,uuid,numeric,text) to authenticated;
revoke all on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) from public,anon;
grant execute on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) to authenticated;

notify pgrst,'reload schema';
commit;

