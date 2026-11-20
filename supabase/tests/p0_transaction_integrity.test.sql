-- P0 transaction regression tests. Run only on a disposable local/test Supabase
-- database after migrations 0001–0048. The transaction rolls back every fixture.
begin;

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values
  ('61000000-0000-4000-8000-000000000001','authenticated','authenticated','p0-owner-a@example.invalid','',now(),now(),now()),
  ('61000000-0000-4000-8000-000000000002','authenticated','authenticated','p0-owner-b@example.invalid','',now(),now(),now());
update public.profiles set is_platform_admin=false
where id in ('61000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000002');

insert into public.organizations(id,name,slug) values
  ('62000000-0000-4000-8000-000000000001','P0 Tenant A','p0-tenant-a'),
  ('62000000-0000-4000-8000-000000000002','P0 Tenant B','p0-tenant-b');
-- This fixture exercises supplier-payables-gated RPCs, so Tenant A needs the
-- Business entitlement. Insert it in the disposable test transaction rather
-- than relying on any organization-creation trigger or production subscription.
insert into public.subscriptions(organization_id,plan_id,status,billing_cycle)
values
  ('62000000-0000-4000-8000-000000000001','business','active','monthly'),
  ('62000000-0000-4000-8000-000000000002','starter','active','monthly');
insert into public.organization_members(organization_id,user_id,role,is_active) values
  ('62000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000001','owner',true),
  ('62000000-0000-4000-8000-000000000002','61000000-0000-4000-8000-000000000002','owner',true);
insert into public.organization_settings(organization_id) values
  ('62000000-0000-4000-8000-000000000001'),('62000000-0000-4000-8000-000000000002');

insert into public.units(organization_id,code,name) values
  ('62000000-0000-4000-8000-000000000001','p0pcs','P0 Pieces'),
  ('62000000-0000-4000-8000-000000000002','p0pcs','P0 Pieces');
insert into public.products(id,organization_id,sku,name,unit_id,purchase_price,sale_price,average_cost,is_active)
select '63000000-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001','P0-A','Product A',u.id,50,100,50,true
from public.units u where u.organization_id='62000000-0000-4000-8000-000000000001' and u.code='p0pcs';
insert into public.products(id,organization_id,sku,name,unit_id,purchase_price,sale_price,average_cost,is_active)
select '63000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000002','P0-B','Product B',u.id,50,100,50,true
from public.units u where u.organization_id='62000000-0000-4000-8000-000000000002' and u.code='p0pcs';

insert into public.customers(id,organization_id,name,is_active) values
  ('64000000-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001','P0 Customer A',true),
  ('64000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000002','P0 Customer B',true);
insert into public.suppliers(id,organization_id,name,is_active) values
  ('65000000-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001','P0 Supplier A',true),
  ('65000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000002','P0 Supplier B',true);

insert into public.purchases(id,organization_id,supplier_id,purchase_number,status,total_amount)
values
  ('68000000-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000001','P0-A-PO-1','ordered',100),
  ('68000000-0000-4000-8000-000000000003','62000000-0000-4000-8000-000000000001',
    '65000000-0000-4000-8000-000000000001','P0-A-PO-2','ordered',100),
  ('68000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000002',
    '65000000-0000-4000-8000-000000000002','P0-B-PO-1','ordered',100);
insert into public.purchase_items(organization_id,purchase_id,product_id,quantity,unit_cost,total_cost)
values('62000000-0000-4000-8000-000000000001','68000000-0000-4000-8000-000000000001',
  '63000000-0000-4000-8000-000000000001',2,50,100),
  ('62000000-0000-4000-8000-000000000001','68000000-0000-4000-8000-000000000003',
  '63000000-0000-4000-8000-000000000001',2,50,100),
  ('62000000-0000-4000-8000-000000000002','68000000-0000-4000-8000-000000000002',
  '63000000-0000-4000-8000-000000000002',2,50,100);

-- Supplier payments cannot point into another tenant even when both global IDs exist.
do $$
begin
  if has_table_privilege('authenticated','public.supplier_payments','INSERT')
      or has_table_privilege('authenticated','public.supplier_payments','UPDATE')
      or has_table_privilege('authenticated','public.supplier_payments','DELETE') then
    raise exception 'FAIL: authenticated role can directly mutate supplier payments';
  end if;
  begin
    insert into public.supplier_payments(organization_id,supplier_id,purchase_id,payment_number,
      amount,payment_method)
    values('62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',
      '68000000-0000-4000-8000-000000000002','P0-CROSS-TENANT-PAYMENT',1,'cash');
    raise exception 'FAIL: cross-tenant supplier payment reference unexpectedly succeeded';
  exception when foreign_key_violation then null;
  end;
end;
$$;

insert into public.stock_movements(organization_id,product_id,movement_type,quantity,unit_cost,reference_type,reference_id)
values ('62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','opening',10,50,'opening','66000000-0000-4000-8000-000000000001');

insert into public.sales(id,organization_id,customer_id,invoice_number,status,subtotal,discount_amount,total_amount)
values
  ('67000000-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001','P0-A-INV-1','draft',100,0,100),
  ('67000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001','P0-A-INV-2','draft',100,0,100);
insert into public.sale_items(organization_id,sale_id,product_id,quantity,unit_price,discount_amount,total_amount)
values
  ('62000000-0000-4000-8000-000000000001','67000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001',1,100,0,100),
  ('62000000-0000-4000-8000-000000000001','67000000-0000-4000-8000-000000000002','63000000-0000-4000-8000-000000000001',1,100,0,100);

-- The composite FK must reject new cross-organization child references.
do $$
begin
  begin
    insert into public.sale_items(organization_id,sale_id,product_id,quantity,unit_price,total_amount)
    values('62000000-0000-4000-8000-000000000001','67000000-0000-4000-8000-000000000002',
      '63000000-0000-4000-8000-000000000002',1,100,100);
    raise exception 'FAIL: cross-tenant product reference unexpectedly succeeded';
  exception when foreign_key_violation then null;
  end;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000001',true);

-- The settings SELECT policy must not reveal Tenant B to Tenant A.
do $$
begin
  if (select count(*) from public.organization_settings) <> 1 then
    raise exception 'FAIL: organization_settings is visible across tenants';
  end if;
end;
$$;

-- Confirm sale computes totals server-side, records one stock movement/payment, and
-- returns the same invoice on retry with the same organization-scoped key.
do $$
declare first_result jsonb; retry_result jsonb; movement_count integer; payment_count integer;
begin
  first_result := public.confirm_sale('62000000-0000-4000-8000-000000000001',
    '67000000-0000-4000-8000-000000000001','cash',100,'p0-sale-key-0001');
  retry_result := public.confirm_sale('62000000-0000-4000-8000-000000000001',
    '67000000-0000-4000-8000-000000000001','cash',100,'p0-sale-key-0001');
  if first_result->>'sale_id' <> retry_result->>'sale_id' or first_result->>'invoice_number' <> retry_result->>'invoice_number' then
    raise exception 'FAIL: idempotent retry returned a different invoice';
  end if;
  if (select total_amount from public.sales where id='67000000-0000-4000-8000-000000000001')<>100 then
    raise exception 'FAIL: server did not calculate the expected sale total';
  end if;
  select count(*) into movement_count from public.stock_movements where reference_type='sale' and reference_id='67000000-0000-4000-8000-000000000001';
  select count(*) into payment_count from public.payments where organization_id='62000000-0000-4000-8000-000000000001' and idempotency_key='sale:p0-sale-key-0001';
  if movement_count<>1 or payment_count<>1 then raise exception 'FAIL: idempotent retry duplicated ledger rows'; end if;
end;
$$;

-- Reject a client-tampered product price before any stock or ledger write.
update public.sale_items set unit_price=50,total_amount=50
where sale_id='67000000-0000-4000-8000-000000000002';
do $$
begin
  begin
    perform public.confirm_sale('62000000-0000-4000-8000-000000000001',
      '67000000-0000-4000-8000-000000000002','cash',0,'p0-sale-tamper-0001');
    raise exception 'FAIL: tampered product price unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Sale price differs from the current approved product price' then raise; end if;
  end;
end;
$$;
update public.sale_items set unit_price=100,total_amount=100
where sale_id='67000000-0000-4000-8000-000000000002';
select public.confirm_sale('62000000-0000-4000-8000-000000000001',
  '67000000-0000-4000-8000-000000000002','cash',0,'p0-sale-key-0002');

-- Cross-customer allocation and over-allocation must abort the whole payment call.
do $$
declare payment_count_before integer; payment_count_after integer; first_result jsonb; retry_result jsonb;
begin
  select count(*) into payment_count_before from public.payments where organization_id='62000000-0000-4000-8000-000000000001';
  begin
    perform public.record_customer_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001',10,'cash',
      '[{"sale_id":"67000000-0000-4000-8000-000000000002","amount":11}]'::jsonb,null,null,'p0-payment-key-001');
    raise exception 'FAIL: over-allocation unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm <> 'Allocations cannot exceed the payment amount' then raise; end if;
  end;
  begin
    perform public.record_customer_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001',120,'cash',
      '[{"sale_id":"67000000-0000-4000-8000-000000000002","amount":101}]'::jsonb,null,null,'p0-payment-key-003');
    raise exception 'FAIL: over-invoice allocation unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm <> 'Allocation exceeds invoice outstanding balance' then raise; end if;
  end;
  begin
    perform public.record_customer_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000002',10,'cash',
      '[{"sale_id":"67000000-0000-4000-8000-000000000001","amount":5}]'::jsonb,null,null,'p0-payment-key-002');
    raise exception 'FAIL: cross-customer allocation unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm <> 'Invoice belongs to another customer' then raise; end if;
  end;
  select count(*) into payment_count_after from public.payments where organization_id='62000000-0000-4000-8000-000000000001';
  if payment_count_after<>payment_count_before then raise exception 'FAIL: rejected payment left a payment row'; end if;

  first_result := public.record_customer_payment_and_allocate(
    '62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001',25,'cash',
    '[{"sale_id":"67000000-0000-4000-8000-000000000002","amount":25}]'::jsonb,
    'P0-RECEIPT-1','same request','p0-customer-retry-001');
  retry_result := public.record_customer_payment_and_allocate(
    '62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001',25.00,'cash',
    '[{"sale_id":"67000000-0000-4000-8000-000000000002","amount":25.00}]'::jsonb,
    'P0-RECEIPT-1','same request','p0-customer-retry-001');
  if first_result->>'payment_id' is distinct from retry_result->>'payment_id' then
    raise exception 'FAIL: equivalent customer payment retry returned a different payment';
  end if;
  begin
    perform public.record_customer_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001',25,'cash',
      '[{"sale_id":"67000000-0000-4000-8000-000000000002","amount":20}]'::jsonb,
      'P0-RECEIPT-1','same request','p0-customer-retry-001');
    raise exception 'FAIL: changed allocation payload reused a customer payment key';
  exception when raise_exception then
    if sqlerrm<>'Idempotency key was already used for a different payment request' then raise; end if;
  end;
  begin
    perform public.record_customer_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001',25,'cash',
      '[{"sale_id":"67000000-0000-4000-8000-000000000002","amount":25}]'::jsonb,
      'P0-RECEIPT-1','changed notes','p0-customer-retry-001');
    raise exception 'FAIL: changed payment metadata reused a customer payment key';
  exception when raise_exception then
    if sqlerrm<>'Idempotency key was already used for a different payment request' then raise; end if;
  end;
  if (select count(*) from public.payments where organization_id='62000000-0000-4000-8000-000000000001'
      and idempotency_key='p0-customer-retry-001')<>1
      or (select paid_amount from public.sales where id='67000000-0000-4000-8000-000000000002')<>25 then
    raise exception 'FAIL: customer payment retry duplicated or changed ledger effects';
  end if;
  select count(*) into payment_count_after from public.payments where organization_id='62000000-0000-4000-8000-000000000001';
  if payment_count_after<>payment_count_before+1 then raise exception 'FAIL: customer retry created duplicate or missing payment rows'; end if;
end;
$$;

-- Receiving twice cannot add duplicate stock or supplier payment rows.
do $$
declare movement_count_before integer; movement_count_after integer; supplier_payment_count integer;
begin
  perform public.receive_purchase('62000000-0000-4000-8000-000000000001',
    '68000000-0000-4000-8000-000000000001',25,'cash');
  select count(*) into movement_count_before from public.stock_movements
    where reference_type='purchase' and reference_id='68000000-0000-4000-8000-000000000001';
  select count(*) into supplier_payment_count from public.supplier_payments
    where purchase_id='68000000-0000-4000-8000-000000000001';
  if movement_count_before<>1 or supplier_payment_count<>1 then raise exception 'FAIL: purchase receipt did not create one ledger movement and payment'; end if;
  begin
    perform public.receive_purchase('62000000-0000-4000-8000-000000000001',
      '68000000-0000-4000-8000-000000000001',25,'cash');
    raise exception 'FAIL: duplicate purchase receipt unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Purchase cannot be received in its current status' then raise; end if;
  end;
  select count(*) into movement_count_after from public.stock_movements
    where reference_type='purchase' and reference_id='68000000-0000-4000-8000-000000000001';
  select count(*) into supplier_payment_count from public.supplier_payments
    where purchase_id='68000000-0000-4000-8000-000000000001';
  if movement_count_after<>movement_count_before or supplier_payment_count<>1 then raise exception 'FAIL: duplicate purchase receipt created ledger rows'; end if;
  perform public.receive_purchase('62000000-0000-4000-8000-000000000001',
    '68000000-0000-4000-8000-000000000003',0,'cash');
end;
$$;

-- Starter allows a purchase paid in full at receipt, but not a partial payment
-- that creates an ongoing supplier payable.
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000002',true);
do $$
begin
  begin
    perform public.receive_purchase('62000000-0000-4000-8000-000000000002',
      '68000000-0000-4000-8000-000000000002',50,'cash');
    raise exception 'FAIL: Starter partial supplier payment unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Partial supplier payments are not available on the current plan' then raise; end if;
  end;
  perform public.receive_purchase('62000000-0000-4000-8000-000000000002',
    '68000000-0000-4000-8000-000000000002',100,'cash');
end;
$$;
select set_config('request.jwt.claim.sub','61000000-0000-4000-8000-000000000001',true);

-- Supplier full/partial payments, multiple-invoice allocation, idempotent retries,
-- unallocated advances, tenant checks, audit writes, and rollback on rejected calls.
do $$
declare
  first_result jsonb;
  retry_result jsonb;
  multi_result jsonb;
  full_result jsonb;
  advance_result jsonb;
  reversal_result jsonb;
  reversal_retry jsonb;
  payment_count integer;
  allocation_count integer;
  reversal_allocation_count integer;
  audit_count integer;
  reversal_audit_count integer;
  payment_count_before integer;
  payment_count_after integer;
  paid_before numeric;
  paid_after numeric;
  paid_purchase_one_before numeric;
  paid_purchase_three_before numeric;
begin
  if has_table_privilege('authenticated','public.supplier_payment_reversals','INSERT')
      or has_table_privilege('authenticated','public.supplier_payment_reversals','UPDATE')
      or has_table_privilege('authenticated','public.supplier_payment_reversals','DELETE')
      or has_table_privilege('authenticated','public.supplier_payment_reversal_allocations','INSERT')
      or has_table_privilege('authenticated','public.supplier_payment_reversal_allocations','UPDATE')
      or has_table_privilege('authenticated','public.supplier_payment_reversal_allocations','DELETE') then
    raise exception 'FAIL: authenticated clients can directly mutate supplier reversal history';
  end if;

  first_result := public.record_supplier_payment_and_allocate(
    '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',20,'cash',
    '[{"purchase_id":"68000000-0000-4000-8000-000000000001","amount":20}]'::jsonb,null,null,'p0-supplier-payment-001');
  retry_result := public.record_supplier_payment_and_allocate(
    '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',20,'cash',
    '[{"purchase_id":"68000000-0000-4000-8000-000000000001","amount":20}]'::jsonb,null,null,'p0-supplier-payment-001');
  if first_result->>'payment_id'<>retry_result->>'payment_id' then raise exception 'FAIL: supplier payment retry returned a different payment'; end if;

  -- Reusing a key with a changed payload must be rejected without a second row.
  begin
    perform public.record_supplier_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',21,'cash',
      '[{"purchase_id":"68000000-0000-4000-8000-000000000001","amount":20}]'::jsonb,null,null,'p0-supplier-payment-001');
    raise exception 'FAIL: changed supplier payment retry unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Idempotency key was already used for a different supplier payment' then raise; end if;
  end;

  -- One supplier payment may be allocated across multiple invoices.
  multi_result := public.record_supplier_payment_and_allocate(
    '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',30,'bank_transfer',
    '[{"purchase_id":"68000000-0000-4000-8000-000000000001","amount":5},
      {"purchase_id":"68000000-0000-4000-8000-000000000003","amount":25}]'::jsonb,null,null,'p0-supplier-payment-multi-001');
  retry_result := public.record_supplier_payment_and_allocate(
    '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',30,'bank_transfer',
    '[{"purchase_id":"68000000-0000-4000-8000-000000000001","amount":5},
      {"purchase_id":"68000000-0000-4000-8000-000000000003","amount":25}]'::jsonb,null,null,'p0-supplier-payment-multi-001');
  if multi_result->>'payment_id'<>retry_result->>'payment_id' then raise exception 'FAIL: multi-invoice retry returned a different payment'; end if;
  select count(*) into allocation_count from public.supplier_payment_allocations
    where organization_id='62000000-0000-4000-8000-000000000001'
      and supplier_payment_id=(multi_result->>'payment_id')::uuid;
  if allocation_count<>2 then raise exception 'FAIL: multi-invoice payment did not create two allocations'; end if;

  -- Fully settle the remaining amount on the first invoice.
  full_result := public.record_supplier_payment_and_allocate(
    '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',50,'cash',
    '[{"purchase_id":"68000000-0000-4000-8000-000000000001","amount":50}]'::jsonb,null,null,'p0-supplier-payment-full-001');
  if (select paid_amount from public.purchases where id='68000000-0000-4000-8000-000000000001')<>100 then
    raise exception 'FAIL: full supplier payment did not settle invoice';
  end if;

  select count(*) into payment_count_before from public.supplier_payments
    where organization_id='62000000-0000-4000-8000-000000000001';
  select paid_amount into paid_before from public.purchases where id='68000000-0000-4000-8000-000000000001';
  -- Total allocations above the payment amount must roll back before any ledger write.
  begin
    perform public.record_supplier_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',10,'cash',
      '[{"purchase_id":"68000000-0000-4000-8000-000000000003","amount":11}]'::jsonb,null,null,'p0-supplier-overpay-001');
    raise exception 'FAIL: allocation above payment amount unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Allocations cannot exceed the payment amount' then raise; end if;
  end;
  -- Invoice over-allocation is rejected even when the payment itself is sufficient.
  begin
    perform public.record_supplier_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',60,'cash',
      '[{"purchase_id":"68000000-0000-4000-8000-000000000001","amount":60}]'::jsonb,null,null,'p0-supplier-overinvoice-001');
    raise exception 'FAIL: allocation above invoice outstanding unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Allocation exceeds purchase payable balance' then raise; end if;
  end;
  select count(*) into payment_count_after from public.supplier_payments
    where organization_id='62000000-0000-4000-8000-000000000001';
  select paid_amount into paid_after from public.purchases where id='68000000-0000-4000-8000-000000000001';
  if payment_count_after<>payment_count_before or paid_after<>paid_before then
    raise exception 'FAIL: rejected supplier payment did not roll back all changes';
  end if;

  -- Both a foreign supplier and a foreign purchase must be rejected.
  begin
    perform public.record_supplier_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000002',5,'cash',
      '[]'::jsonb,null,null,'p0-supplier-cross-tenant-001');
    raise exception 'FAIL: cross-tenant supplier unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Supplier does not belong to this organization or is inactive' then raise; end if;
  end;
  begin
    perform public.record_supplier_payment_and_allocate(
      '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',5,'cash',
      '[{"purchase_id":"68000000-0000-4000-8000-000000000002","amount":5}]'::jsonb,null,null,'p0-purchase-cross-tenant-001');
    raise exception 'FAIL: cross-tenant purchase unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Purchase does not belong to this organization' then raise; end if;
  end;

  advance_result := public.record_supplier_payment_and_allocate(
    '62000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',10,'cash','[]'::jsonb,null,null,'p0-supplier-advance-001');
  if (advance_result->>'unallocated_amount')::numeric<>10 then raise exception 'FAIL: supplier advance was not retained as unallocated'; end if;

  -- A reversal is an immutable compensating record, restores each invoice once,
  -- and returns the same result for an equivalent retry.
  select paid_amount into paid_purchase_one_before from public.purchases where id='68000000-0000-4000-8000-000000000001';
  select paid_amount into paid_purchase_three_before from public.purchases where id='68000000-0000-4000-8000-000000000003';
  reversal_result := public.reverse_supplier_payment(
    '62000000-0000-4000-8000-000000000001',(multi_result->>'payment_id')::uuid,
    'Duplicate bank transfer entered by mistake','p0-supplier-reversal-multi-001');
  reversal_retry := public.reverse_supplier_payment(
    '62000000-0000-4000-8000-000000000001',(multi_result->>'payment_id')::uuid,
    'Duplicate bank transfer entered by mistake','p0-supplier-reversal-multi-001');
  if reversal_result->>'reversal_id' is distinct from reversal_retry->>'reversal_id'
      or reversal_retry->>'replayed'<>'true' then
    raise exception 'FAIL: supplier reversal retry did not return the original reversal';
  end if;
  if (select paid_amount from public.purchases where id='68000000-0000-4000-8000-000000000001')<>paid_purchase_one_before-5
      or (select paid_amount from public.purchases where id='68000000-0000-4000-8000-000000000003')<>paid_purchase_three_before-25 then
    raise exception 'FAIL: supplier reversal did not restore allocated purchase balances exactly once';
  end if;
  select count(*) into reversal_allocation_count from public.supplier_payment_reversal_allocations
    where organization_id='62000000-0000-4000-8000-000000000001'
      and reversal_id=(reversal_result->>'reversal_id')::uuid;
  if reversal_allocation_count<>2 then raise exception 'FAIL: reversal allocation audit is incomplete'; end if;
  begin
    perform public.reverse_supplier_payment(
      '62000000-0000-4000-8000-000000000002',(multi_result->>'payment_id')::uuid,
      'Cross organization attempt','p0-supplier-reversal-cross-tenant-001');
    raise exception 'FAIL: cross-tenant supplier payment reversal unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Unauthorized' then raise; end if;
  end;
  begin
    perform public.reverse_supplier_payment(
      '62000000-0000-4000-8000-000000000001',(multi_result->>'payment_id')::uuid,
      'Different request reason','p0-supplier-reversal-multi-other-001');
    raise exception 'FAIL: already reversed supplier payment was reversed twice';
  exception when raise_exception then
    if sqlerrm<>'Supplier payment is already reversed' then raise; end if;
  end;
  begin
    perform public.reverse_supplier_payment(
      '62000000-0000-4000-8000-000000000001',(multi_result->>'payment_id')::uuid,
      'Changed reason on retry','p0-supplier-reversal-multi-001');
    raise exception 'FAIL: changed reversal retry unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm<>'Idempotency key was already used for a different supplier payment reversal' then raise; end if;
  end;

  -- Advances without invoice allocations can be reversed without touching a purchase.
  reversal_result := public.reverse_supplier_payment(
    '62000000-0000-4000-8000-000000000001',(advance_result->>'payment_id')::uuid,
    'Advance returned to bank','p0-supplier-reversal-advance-001');
  if (reversal_result->>'amount')::numeric<>10 then raise exception 'FAIL: unallocated advance reversal amount is incorrect'; end if;

  -- Successful payment creation is auditable exactly once despite duplicate retries.
  select count(*) into audit_count from public.audit_logs
    where organization_id='62000000-0000-4000-8000-000000000001'
      and action='supplier_payment.create'
      and entity_id in ((first_result->>'payment_id')::uuid,(multi_result->>'payment_id')::uuid,
        (full_result->>'payment_id')::uuid,(advance_result->>'payment_id')::uuid);
  if audit_count<>4 then raise exception 'FAIL: supplier payment audit history is missing or duplicated'; end if;
  select count(*) into reversal_audit_count from public.audit_logs
    where organization_id='62000000-0000-4000-8000-000000000001'
      and action='supplier_payment.reverse'
      and entity_id in ((multi_result->>'payment_id')::uuid,(advance_result->>'payment_id')::uuid);
  if reversal_audit_count<>2 then raise exception 'FAIL: supplier reversal audit history is missing or duplicated'; end if;
end;
$$;

rollback;

