-- Disposable database integration assertions; no pgTAP extension is required.
-- Run with `supabase test db` or psql only against a local disposable database.
begin;

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('10000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'erp-test-a@example.invalid', '', now(), now(), now()),
  ('20000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'erp-test-b@example.invalid', '', now(), now(), now()),
  ('30000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'erp-test-viewer@example.invalid', '', now(), now(), now()),
  ('40000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'erp-test-sales@example.invalid', '', now(), now(), now());

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select set_config('test.org_a', public.create_organization('Test Organization A')::text, true);
select set_config('test.product_a', public.create_product(
  current_setting('test.org_a')::uuid,
  'TEST-SKU-1', 'Test Product',
  (select id from public.units where org_id = current_setting('test.org_a')::uuid and code = 'ea'),
  null, null, null, 100, 150, true
)::text, true);
select set_config('test.warehouse_a', (
  select id::text from public.warehouses
  where org_id = current_setting('test.org_a')::uuid and is_default
), true);

reset role;
insert into public.memberships (org_id, user_id, role, is_active)
values
  (current_setting('test.org_a')::uuid, '30000000-0000-4000-8000-000000000003', 'viewer', true),
  (current_setting('test.org_a')::uuid, '40000000-0000-4000-8000-000000000004', 'sales_staff', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);

-- Assertions throw and fail the test transaction on any unexpected behavior.
do $$
declare
  v_movement_id uuid;
  v_retry_id uuid;
  v_sale_id uuid;
  v_sale_retry_id uuid;
begin
  if has_table_privilege('authenticated', 'public.stock_movements', 'INSERT') then
    raise exception 'FAIL: authenticated clients can directly insert stock movements';
  end if;
  if has_table_privilege('authenticated', 'public.products', 'INSERT')
     or has_table_privilege('authenticated', 'public.products', 'UPDATE') then
    raise exception 'FAIL: authenticated clients can directly write products';
  end if;
  if has_table_privilege('authenticated', 'public.sales', 'INSERT')
     or has_table_privilege('authenticated', 'public.customers', 'UPDATE') then
    raise exception 'FAIL: authenticated clients can bypass sales/customer RPC workflows';
  end if;
  if has_function_privilege('anon', 'public.adjust_inventory(uuid,uuid,uuid,numeric,text,uuid)', 'EXECUTE') then
    raise exception 'FAIL: anonymous role can execute inventory adjustment RPC';
  end if;
  if (select count(*) from public.products where org_id = current_setting('test.org_a')::uuid) <> 1 then
    raise exception 'FAIL: organization A cannot read its own product';
  end if;
  if (select count(*) from public.stock_balances where org_id = current_setting('test.org_a')::uuid) <> 1 then
    raise exception 'FAIL: stock balance compatibility view did not return the organization product';
  end if;

  begin
    perform public.create_product(
      current_setting('test.org_a')::uuid,
      'BAD-PRICE', 'Invalid Price',
      (select id from public.units where org_id = current_setting('test.org_a')::uuid and code = 'ea'),
      null, null, null, 100, 12.345, true
    );
    raise exception 'FAIL: product create accepted a price with invalid precision';
  exception when invalid_parameter_value then
    if sqlerrm <> 'ကုန်ကျဈေးနှင့် ရောင်းဈေးသည် သုည သို့မဟုတ် ထို့ထက်ပိုရပါမည်။' then raise; end if;
  end;

  perform public.update_product(
    current_setting('test.org_a')::uuid,
    current_setting('test.product_a')::uuid,
    'TEST-SKU-1', 'Test Product Updated',
    (select id from public.units where org_id = current_setting('test.org_a')::uuid and code = 'ea'),
    null, null, 'Updated', 100, 150, true, 2
  );
  if (select name from public.products where org_id = current_setting('test.org_a')::uuid and id = current_setting('test.product_a')::uuid) <> 'Test Product Updated' then
    raise exception 'FAIL: authorized product update did not persist';
  end if;
  perform public.set_product_active(current_setting('test.org_a')::uuid, current_setting('test.product_a')::uuid, false);
  if (select is_active from public.products where org_id = current_setting('test.org_a')::uuid and id = current_setting('test.product_a')::uuid) then
    raise exception 'FAIL: authorized product deactivation did not persist';
  end if;
  perform public.set_product_active(current_setting('test.org_a')::uuid, current_setting('test.product_a')::uuid, true);

  v_movement_id := public.adjust_inventory(
    current_setting('test.org_a')::uuid, current_setting('test.product_a')::uuid,
    current_setting('test.warehouse_a')::uuid, 80,
    'Opening receipt for test', '30000000-0000-4000-8000-000000000003'
  );
  v_retry_id := public.adjust_inventory(
    current_setting('test.org_a')::uuid, current_setting('test.product_a')::uuid,
    current_setting('test.warehouse_a')::uuid, 80,
    'Opening receipt for test', '30000000-0000-4000-8000-000000000003'
  );
  if v_retry_id <> v_movement_id then raise exception 'FAIL: adjustment retry returned a different movement'; end if;
  begin
    perform public.adjust_inventory(
      current_setting('test.org_a')::uuid, current_setting('test.product_a')::uuid,
      current_setting('test.warehouse_a')::uuid, 81,
      'Opening receipt for test', '30000000-0000-4000-8000-000000000003'
    );
    raise exception 'FAIL: idempotency key accepted a different adjustment payload';
  exception when unique_violation then
    if sqlerrm <> 'ဤလုပ်ဆောင်မှုသော့ကို အခြားစတော့ပြင်ဆင်မှုတွင် အသုံးပြုပြီးပါပြီ။' then raise; end if;
  end;
  if (select quantity from public.inventory_balances where org_id = current_setting('test.org_a')::uuid and product_id = current_setting('test.product_a')::uuid and warehouse_id = current_setting('test.warehouse_a')::uuid) <> 80 then
    raise exception 'FAIL: adjustment retry changed the balance';
  end if;
  begin
    perform public.adjust_inventory(current_setting('test.org_a')::uuid,current_setting('test.product_a')::uuid,
      current_setting('test.warehouse_a')::uuid,0.5,'Fractional each test','32000000-0000-4000-8000-000000000003');
    raise exception 'FAIL: zero-decimal unit accepted fractional stock';
  exception when invalid_parameter_value then
    if sqlerrm<>'ရွေးချယ်ထားသော ယူနစ်၏ ဒဿမတိကျမှုထက် ပိုမိုသော အရေအတွက် ဖြစ်နေပါသည်။' then raise; end if;
  end;
  begin
    perform public.update_product(current_setting('test.org_a')::uuid,current_setting('test.product_a')::uuid,
      'TEST-SKU-1','Test Product Updated',(select id from public.units where org_id=current_setting('test.org_a')::uuid and code='ea'),
      null,null,'Updated',100,150,false,2);
    raise exception 'FAIL: stocked product tracking was disabled';
  exception when check_violation then
    if sqlerrm<>'လက်ကျန်ရှိသော ကုန်ပစ္စည်းကို စတော့ခြေရာခံမှု ပိတ်၍မရပါ။ အရင်စာရင်းရှင်းပါ။' then raise; end if;
  end;
  if (select count(*) from public.stock_movements where org_id = current_setting('test.org_a')::uuid and idempotency_key = '30000000-0000-4000-8000-000000000003') <> 1 then
    raise exception 'FAIL: adjustment retry created duplicate movements';
  end if;

  v_sale_id := public.create_sale(
    current_setting('test.org_a')::uuid,
    jsonb_build_array(jsonb_build_object('product_id', current_setting('test.product_a')::uuid, 'quantity', 3)),
    null, 'cash', '60000000-0000-4000-8000-000000000006'
  );
  v_sale_retry_id := public.create_sale(
    current_setting('test.org_a')::uuid,
    jsonb_build_array(jsonb_build_object('product_id', current_setting('test.product_a')::uuid, 'quantity', 3)),
    null, 'cash', '60000000-0000-4000-8000-000000000006'
  );
  if v_sale_retry_id <> v_sale_id then raise exception 'FAIL: same-user sale retry did not return its invoice'; end if;
  perform set_config('test.sale_a', v_sale_id::text, true);
  if (select total_amount from public.sales where org_id = current_setting('test.org_a')::uuid and id = v_sale_id) <> 450 then
    raise exception 'FAIL: sale total did not use server-side price';
  end if;
  if (select unit_cost from public.sale_items where org_id = current_setting('test.org_a')::uuid and sale_id = v_sale_id) <> 100 then
    raise exception 'FAIL: sale item cost snapshot is incorrect';
  end if;
  if (select quantity from public.inventory_balances where org_id = current_setting('test.org_a')::uuid and product_id = current_setting('test.product_a')::uuid and warehouse_id = current_setting('test.warehouse_a')::uuid) <> 77 then
    raise exception 'FAIL: sale did not decrement stock exactly once';
  end if;

  begin
    perform public.create_sale(current_setting('test.org_a')::uuid, null, null, 'cash', '62000000-0000-4000-8000-000000000006');
    raise exception 'FAIL: create_sale accepted null items';
  exception when invalid_parameter_value then
    if sqlerrm <> 'အရောင်းကုန်ပစ္စည်းစာရင်းကို စစ်ဆေးပါ။' then raise; end if;
  end;
  begin
    perform public.create_sale(
      current_setting('test.org_a')::uuid,
      jsonb_build_array(jsonb_build_object('product_id', current_setting('test.product_a')::uuid, 'quantity', 78)),
      null, 'cash', '61000000-0000-4000-8000-000000000006'
    );
    raise exception 'FAIL: sale was allowed to consume more than available stock';
  exception when check_violation then
    if sqlerrm <> 'လက်ကျန်ပစ္စည်း မလုံလောက်ပါ။' then raise; end if;
  end;
  if exists (select 1 from public.sales where org_id = current_setting('test.org_a')::uuid and idempotency_key = '61000000-0000-4000-8000-000000000006') then
    raise exception 'FAIL: rejected sale left an invoice behind';
  end if;
  if (select quantity from public.inventory_balances where org_id = current_setting('test.org_a')::uuid and product_id = current_setting('test.product_a')::uuid and warehouse_id = current_setting('test.warehouse_a')::uuid) <> 77 then
    raise exception 'FAIL: rejected sale changed inventory';
  end if;
  begin
    perform public.adjust_inventory(
      current_setting('test.org_a')::uuid, current_setting('test.product_a')::uuid,
      current_setting('test.warehouse_a')::uuid, -78, 'Overdraw test',
      '40000000-0000-4000-8000-000000000004'
    );
    raise exception 'FAIL: inventory was allowed to become negative';
  exception when check_violation then
    if sqlerrm <> 'လက်ကျန်ထက် ပိုမိုလျှော့ချ၍ မရပါ။' then raise; end if;
  end;
end;
$$;

select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000003', true);
do $$
begin
  begin
    perform public.create_product(current_setting('test.org_a')::uuid,'VIEWER-SKU','Viewer Product',
      (select id from public.units where org_id=current_setting('test.org_a')::uuid and code='ea'));
    raise exception 'FAIL: viewer role created a product';
  exception when insufficient_privilege then
    if sqlerrm<>'ဤလုပ်ငန်းတွင် ကုန်ပစ္စည်းဖန်တီးခွင့် မရှိပါ။' then raise; end if;
  end;
  begin
    perform public.adjust_inventory(current_setting('test.org_a')::uuid,current_setting('test.product_a')::uuid,
      current_setting('test.warehouse_a')::uuid,1,'Viewer adjustment','51000000-0000-4000-8000-000000000005');
    raise exception 'FAIL: viewer role adjusted inventory';
  exception when insufficient_privilege then
    if sqlerrm<>'ဤလုပ်ငန်းတွင် စတော့ပြင်ဆင်ခွင့် မရှိပါ။' then raise; end if;
  end;
  begin
    perform public.set_product_active(current_setting('test.org_a')::uuid, current_setting('test.product_a')::uuid, false);
    raise exception 'FAIL: viewer role deactivated a product';
  exception when insufficient_privilege then
    if sqlerrm <> 'ဤလုပ်ငန်းတွင် ကုန်ပစ္စည်းအခြေအနေ ပြင်ဆင်ခွင့် မရှိပါ။' then raise; end if;
  end;
end;
$$;

select set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000004', true);
do $$
declare v_other_user_sale uuid;
begin
  v_other_user_sale := public.create_sale(
    current_setting('test.org_a')::uuid,
    jsonb_build_array(jsonb_build_object('product_id', current_setting('test.product_a')::uuid, 'quantity', 3)),
    null, 'cash', '60000000-0000-4000-8000-000000000006'
  );
  if v_other_user_sale = current_setting('test.sale_a')::uuid then
    raise exception 'FAIL: another user received the first user sale as an idempotent replay';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub', '20000000-0000-4000-8000-000000000002', true);
do $$
declare v_org_b uuid;
begin
  v_org_b := public.create_organization('Test Organization B');
  if exists (select 1 from public.products where id = current_setting('test.product_a')::uuid) then
    raise exception 'FAIL: organization B can read organization A product';
  end if;
  if exists (select 1 from public.stock_balances where product_id = current_setting('test.product_a')::uuid) then
    raise exception 'FAIL: organization B can read organization A stock through the compatibility view';
  end if;
  if exists (select 1 from public.sales where id = current_setting('test.sale_a')::uuid) then
    raise exception 'FAIL: organization B can read organization A sales';
  end if;
  begin
    perform public.adjust_inventory(
      current_setting('test.org_a')::uuid, current_setting('test.product_a')::uuid,
      current_setting('test.warehouse_a')::uuid, 1, 'Cross organization test',
      '50000000-0000-4000-8000-000000000005'
    );
    raise exception 'FAIL: organization B adjusted organization A inventory';
  exception when insufficient_privilege then
    if sqlerrm <> 'ဤလုပ်ငန်းတွင် စတော့ပြင်ဆင်ခွင့် မရှိပါ။' then raise; end if;
  end;
  if v_org_b = current_setting('test.org_a')::uuid then raise exception 'FAIL: organization IDs are not unique'; end if;
end;
$$;

reset role;
do $$
begin
  begin
    update public.stock_movements set reason = 'tampered'
    where org_id = current_setting('test.org_a')::uuid
      and idempotency_key = '30000000-0000-4000-8000-000000000003';
    raise exception 'FAIL: privileged database role modified an immutable stock movement';
  exception when object_not_in_prerequisite_state then
    if sqlerrm <> 'စတော့လှုပ်ရှားမှုမှတ်တမ်းကို ပြင်ဆင်/ဖျက်၍မရပါ။ ပြန်လည်ပြင်ဆင်မှုအသစ် မှတ်တမ်းတင်ပါ။' then raise; end if;
  end;
end;
$$;

rollback;
