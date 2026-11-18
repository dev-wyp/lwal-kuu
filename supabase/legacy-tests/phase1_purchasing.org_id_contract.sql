-- Purchasing/receiving/payables integration checks. Disposable local DB only.
begin;
insert into auth.users (id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('70000000-0000-4000-8000-000000000007','authenticated','authenticated','purchase-test@example.invalid','',now(),now(),now());
set local role authenticated;
select set_config('request.jwt.claim.sub','70000000-0000-4000-8000-000000000007',true);
select set_config('purchase.test_org',public.create_organization('Purchase Test Organization')::text,true);
select set_config('purchase.supplier',public.create_supplier(current_setting('purchase.test_org')::uuid,'Test Supplier','SUP-1')::text,true);
select set_config('purchase.product',public.create_product(
  current_setting('purchase.test_org')::uuid,'PUR-1','Receipt Test Product',
  (select id from public.units where org_id=current_setting('purchase.test_org')::uuid and code='ea'),
  null,null,null,100,150,true
)::text,true);
select set_config('purchase.warehouse',(
  select id::text from public.warehouses where org_id=current_setting('purchase.test_org')::uuid and is_default
),true);

-- Create an order and verify it has not changed stock.
select set_config('purchase.order',public.create_purchase_order(
  current_setting('purchase.test_org')::uuid,
  current_setting('purchase.supplier')::uuid,
  jsonb_build_array(jsonb_build_object('product_id',current_setting('purchase.product')::uuid,'quantity',100,'unit_cost',100)),
  null,0,0,'100-unit order','71000000-0000-4000-8000-000000000007'
)::text,true);
do $$
begin
  if exists(select 1 from public.inventory_balances where org_id=current_setting('purchase.test_org')::uuid and product_id=current_setting('purchase.product')::uuid) then
    raise exception 'FAIL: purchase order increased inventory';
  end if;
end;
$$;

select set_config('purchase.item',(
  select id::text from public.purchase_items where org_id=current_setting('purchase.test_org')::uuid and purchase_id=current_setting('purchase.order')::uuid
),true);
do $$
begin
  if (select total_amount from public.purchases where org_id=current_setting('purchase.test_org')::uuid and id=current_setting('purchase.order')::uuid)<>10000 then
    raise exception 'FAIL: purchase total does not match quantity multiplied by unit cost';
  end if;
  if (select unit_cost from public.purchase_items where org_id=current_setting('purchase.test_org')::uuid and id=current_setting('purchase.item')::uuid)<>100 then
    raise exception 'FAIL: purchase unit cost was not persisted correctly';
  end if;
end;
$$;
select set_config('purchase.receipt_one',public.post_goods_receipt(
  current_setting('purchase.test_org')::uuid,current_setting('purchase.order')::uuid,current_setting('purchase.warehouse')::uuid,
  jsonb_build_array(jsonb_build_object('purchase_item_id',current_setting('purchase.item')::uuid,'quantity_received',80,'quantity_accepted',80,'quantity_rejected',0)),
  'First partial delivery','72000000-0000-4000-8000-000000000007'
)::text,true);
select set_config('purchase.receipt_one_retry',public.post_goods_receipt(
  current_setting('purchase.test_org')::uuid,current_setting('purchase.order')::uuid,current_setting('purchase.warehouse')::uuid,
  jsonb_build_array(jsonb_build_object('purchase_item_id',current_setting('purchase.item')::uuid,'quantity_received',80,'quantity_accepted',80,'quantity_rejected',0)),
  'First partial delivery','72000000-0000-4000-8000-000000000007'
)::text,true);
select set_config('purchase.receipt_two',public.post_goods_receipt(
  current_setting('purchase.test_org')::uuid,current_setting('purchase.order')::uuid,current_setting('purchase.warehouse')::uuid,
  jsonb_build_array(jsonb_build_object('purchase_item_id',current_setting('purchase.item')::uuid,'quantity_received',20,'quantity_accepted',20,'quantity_rejected',0)),
  'Second partial delivery','73000000-0000-4000-8000-000000000007'
)::text,true);

do $$
begin
  if current_setting('purchase.receipt_one')<>current_setting('purchase.receipt_one_retry') then raise exception 'FAIL: receipt retry did not return the original receipt'; end if;
  if (select quantity from public.inventory_balances where org_id=current_setting('purchase.test_org')::uuid and product_id=current_setting('purchase.product')::uuid and warehouse_id=current_setting('purchase.warehouse')::uuid)<>100 then raise exception 'FAIL: multiple receipts did not post exactly 100 accepted units'; end if;
  if (select count(*) from public.stock_movements where org_id=current_setting('purchase.test_org')::uuid and reference_type='goods_receipt')<>2 then raise exception 'FAIL: receipt retry duplicated stock movement'; end if;
  if (select status from public.purchases where org_id=current_setting('purchase.test_org')::uuid and id=current_setting('purchase.order')::uuid)<>'received' then raise exception 'FAIL: fully received purchase has wrong status'; end if;
  if (select sum(balance_delta) from public.supplier_liability_entries where org_id=current_setting('purchase.test_org')::uuid and account_bucket='grni')<>10000 then raise exception 'FAIL: GRNI does not equal accepted inventory cost'; end if;
  begin
    perform public.post_goods_receipt(current_setting('purchase.test_org')::uuid,current_setting('purchase.order')::uuid,current_setting('purchase.warehouse')::uuid,
      jsonb_build_array(jsonb_build_object('purchase_item_id',current_setting('purchase.item')::uuid,'quantity_received',1,'quantity_accepted',1,'quantity_rejected',0)),
      'Excess receipt','74000000-0000-4000-8000-000000000007');
    raise exception 'FAIL: receipt over-received ordered quantity';
  exception when check_violation then
    if sqlerrm<>'လက်ခံနိုင်သော ဝယ်ယူမှု မရှိပါ။' then raise; end if;
  end;
end;
$$;

select set_config('purchase.invoice',public.post_supplier_invoice(
  current_setting('purchase.test_org')::uuid,current_setting('purchase.order')::uuid,'SUP-INV-1',current_date,current_date+30,
  jsonb_build_array(
    jsonb_build_object('receipt_id',current_setting('purchase.receipt_one')::uuid,'amount',8200,'grni_amount',8000),
    jsonb_build_object('receipt_id',current_setting('purchase.receipt_two')::uuid,'amount',2000,'grni_amount',2000)
  ),'Test supplier invoice','75000000-0000-4000-8000-000000000007'
)::text,true);
select set_config('purchase.invoice_retry',public.post_supplier_invoice(
  current_setting('purchase.test_org')::uuid,current_setting('purchase.order')::uuid,'SUP-INV-1',current_date,current_date+30,
  jsonb_build_array(
    jsonb_build_object('receipt_id',current_setting('purchase.receipt_one')::uuid,'amount',8200,'grni_amount',8000),
    jsonb_build_object('receipt_id',current_setting('purchase.receipt_two')::uuid,'amount',2000,'grni_amount',2000)
  ),'Test supplier invoice','75000000-0000-4000-8000-000000000007'
)::text,true);
select set_config('purchase.payment',public.post_supplier_payment(
  current_setting('purchase.test_org')::uuid,current_setting('purchase.supplier')::uuid,current_date,2500,'cash','PAY-REF','Partial settlement',
  jsonb_build_array(jsonb_build_object('invoice_id',current_setting('purchase.invoice')::uuid,'amount',2500)),
  '76000000-0000-4000-8000-000000000007'
)::text,true);
select set_config('purchase.payment_retry',public.post_supplier_payment(
  current_setting('purchase.test_org')::uuid,current_setting('purchase.supplier')::uuid,current_date,2500,'cash','PAY-REF','Partial settlement',
  jsonb_build_array(jsonb_build_object('invoice_id',current_setting('purchase.invoice')::uuid,'amount',2500)),
  '76000000-0000-4000-8000-000000000007'
)::text,true);
select set_config('purchase.advance',public.post_supplier_payment(
  current_setting('purchase.test_org')::uuid,current_setting('purchase.supplier')::uuid,current_date,1000,'bank_transfer','ADV-REF','Unallocated advance',
  '[]'::jsonb,'78000000-0000-4000-8000-000000000007'
)::text,true);

do $$
begin
  if current_setting('purchase.invoice')<>current_setting('purchase.invoice_retry') then raise exception 'FAIL: invoice retry returned a different invoice'; end if;
  if current_setting('purchase.payment')<>current_setting('purchase.payment_retry') then raise exception 'FAIL: payment retry returned a different payment'; end if;
  if (select sum(balance_delta) from public.supplier_liability_entries where org_id=current_setting('purchase.test_org')::uuid and account_bucket='grni')<>0 then raise exception 'FAIL: invoice did not clear received GRNI'; end if;
  if (select sum(balance_delta) from public.supplier_liability_entries where org_id=current_setting('purchase.test_org')::uuid and supplier_invoice_id=current_setting('purchase.invoice')::uuid and account_bucket='accounts_payable')<>7700 then raise exception 'FAIL: actual supplier invoice balance after partial payment is incorrect'; end if;
  if (select sum(balance_delta) from public.supplier_liability_entries where org_id=current_setting('purchase.test_org')::uuid and supplier_invoice_id=current_setting('purchase.invoice')::uuid and account_bucket='supplier_invoice_variance')<>200 then raise exception 'FAIL: supplier invoice price variance was not recorded'; end if;
  if (select sum(balance_delta) from public.supplier_liability_entries where org_id=current_setting('purchase.test_org')::uuid and supplier_payment_id=current_setting('purchase.payment')::uuid and account_bucket='supplier_advance')<>0 then raise exception 'FAIL: fully allocated payment created an advance'; end if;
  if (select sum(balance_delta) from public.supplier_liability_entries where org_id=current_setting('purchase.test_org')::uuid and supplier_invoice_id=current_setting('purchase.invoice')::uuid and account_bucket='accounts_payable')<>7700 then raise exception 'FAIL: duplicate payment/invoice retry changed the payable'; end if;
  if (select sum(balance_delta) from public.supplier_liability_entries where org_id=current_setting('purchase.test_org')::uuid and supplier_payment_id=current_setting('purchase.advance')::uuid and account_bucket='supplier_advance')<>1000 then raise exception 'FAIL: unapplied payment was not recorded as supplier advance'; end if;
  begin
    perform public.post_supplier_payment(current_setting('purchase.test_org')::uuid,current_setting('purchase.supplier')::uuid,current_date,8000,'cash',null,null,
      jsonb_build_array(jsonb_build_object('invoice_id',current_setting('purchase.invoice')::uuid,'amount',8000)),
      '77000000-0000-4000-8000-000000000007');
    raise exception 'FAIL: payment over-allocated invoice outstanding';
  exception when check_violation then
    if sqlerrm<>'ငွေပေးချေမှုသည် ဘောင်ချာလက်ကျန်ထက် ကျော်လွန်ပါသည်။' then raise; end if;
  end;
end;
$$;

rollback;
