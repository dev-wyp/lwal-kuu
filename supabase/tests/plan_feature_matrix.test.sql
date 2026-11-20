-- Regression assertions for the advertised Starter/Business/Pro feature and
-- resource-limit matrix, custom-plan independence, and direct quota enforcement.
-- Run after migrations 0001–0047 on a disposable DB.
begin;

-- One authenticated owner per standard plan lets the suite verify runtime RPC
-- decisions as well as stored matrix rows.
insert into auth.users (id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values
  ('81000000-0000-4000-8000-000000000001','authenticated','authenticated','matrix-starter@example.invalid','',now(),now(),now()),
  ('81000000-0000-4000-8000-000000000002','authenticated','authenticated','matrix-business@example.invalid','',now(),now(),now()),
  ('81000000-0000-4000-8000-000000000003','authenticated','authenticated','matrix-pro@example.invalid','',now(),now(),now()),
  ('81000000-0000-4000-8000-000000000004','authenticated','authenticated','matrix-custom@example.invalid','',now(),now(),now()),
  ('81000000-0000-4000-8000-000000000005','authenticated','authenticated','matrix-over-limit@example.invalid','',now(),now(),now()),
  ('81000000-0000-4000-8000-000000000006','authenticated','authenticated','matrix-expired@example.invalid','',now(),now(),now());
insert into public.organizations(id,name,slug) values
  ('82000000-0000-4000-8000-000000000001','Matrix Starter','matrix-starter-test'),
  ('82000000-0000-4000-8000-000000000002','Matrix Business','matrix-business-test'),
  ('82000000-0000-4000-8000-000000000003','Matrix Pro','matrix-pro-test'),
  ('82000000-0000-4000-8000-000000000004','Matrix Custom','matrix-custom-test'),
  ('82000000-0000-4000-8000-000000000005','Matrix Expired','matrix-expired-test');
insert into public.plans(
  id,name,description,slug,price,billing_interval,monthly_price_mmk,yearly_price_mmk,trial_days,
  max_users,max_products,max_monthly_sales,features,is_active,is_public,display_order,currency,
  max_customers,max_suppliers,max_branches
)
values(
  'matrix-custom-test','Matrix Custom Plan','Disposable custom plan fixture','matrix-custom-test',5000,'month',
  5000,50000,14,2,50,-1,'{}'::jsonb,true,false,99,'MMK',50,25,1
);
insert into public.plan_features(plan_id,feature_id,is_enabled)
select 'matrix-custom-test',id,feature_key in ('cash_sales','max_users')
from public.features where is_active and feature_key in ('cash_sales','max_users');
insert into public.plan_feature_limits(plan_id,feature_id,limit_value,limit_unit)
select 'matrix-custom-test',id,2,'users' from public.features where feature_key='max_users';
insert into public.subscriptions(organization_id,plan_id,status,billing_cycle)
values
  ('82000000-0000-4000-8000-000000000001','starter','active','monthly'),
  ('82000000-0000-4000-8000-000000000002','business','active','monthly'),
  ('82000000-0000-4000-8000-000000000003','pro','active','monthly'),
  ('82000000-0000-4000-8000-000000000004','matrix-custom-test','active','monthly'),
  ('82000000-0000-4000-8000-000000000005','starter','active','monthly');
insert into public.organization_members(organization_id,user_id,role,is_active)
values
  ('82000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001','owner',true),
  ('82000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000002','owner',true),
  ('82000000-0000-4000-8000-000000000003','81000000-0000-4000-8000-000000000003','owner',true),
  ('82000000-0000-4000-8000-000000000004','81000000-0000-4000-8000-000000000004','owner',true),
  ('82000000-0000-4000-8000-000000000005','81000000-0000-4000-8000-000000000006','owner',true);
update public.subscriptions
set current_period_end=now()-interval '1 day',expires_at=now()-interval '1 day'
where organization_id='82000000-0000-4000-8000-000000000005';

do $$
declare
  expected record;
  view_gate record;
  runtime_plan record;
  runtime_feature record;
  access_result jsonb;
  entitlement_result jsonb;
  expected_limit jsonb;
  limit_decision jsonb;
  org_id uuid;
  user_id uuid;
  expected_usage integer;
  expected_allowed boolean;
  enabled_count integer;
  active_boolean_count integer;
  active_limit_count integer;
begin
  select count(*) into active_boolean_count
  from public.features where is_active and feature_type='boolean';
  if active_boolean_count <> 42 then
    raise exception 'FAIL: expected 42 active boolean features, found %', active_boolean_count;
  end if;

  select count(*) into active_limit_count
  from public.features where is_active and feature_type='limit';
  if active_limit_count <> 5 then
    raise exception 'FAIL: expected 5 active limit features, found %', active_limit_count;
  end if;
  if exists (
    select 1 from public.features
    where is_active and feature_type='limit'
      and feature_key not in ('max_users','max_products','max_customers','max_suppliers','max_branches')
  ) then
    raise exception 'FAIL: an unrecognized active limit feature exists';
  end if;

  for view_gate in
    select * from (values
      ('daily_sales_performance','daily_sales_report'),
      ('product_sales_performance','basic_product_report'),
      ('monthly_sales_performance','monthly_yearly_reports'),
      ('yearly_sales_performance','monthly_yearly_reports'),
      ('purchase_analytics','purchase_analytics'),
      ('profit_loss_performance','profit_loss_report'),
      ('cash_flow_performance','cash_flow_report'),
      ('branch_sales_performance','branch_reports'),
      ('branch_stock_balances','multi_branch')
    ) as gates(view_name,feature_key)
  loop
    if position(view_gate.feature_key in pg_get_viewdef(
      to_regclass('public.' || view_gate.view_name), true
    )) = 0 then
      raise exception 'FAIL: report view % lacks its plan entitlement predicate', view_gate.view_name;
    end if;
  end loop;

  for expected in
    select * from (values
      ('starter', array[
        'product_management','category_management','customer_management','supplier_management',
        'purchase_management','sales_management','cash_sales','inventory_management',
        'stock_adjustment','daily_sales_report','basic_product_report','manual_data_export'
      ]::text[]),
      ('business', array[
        'product_management','category_management','customer_management','supplier_management',
        'purchase_management','sales_management','cash_sales','credit_sales','partial_payments',
        'customer_ledger','customer_debt_tracking','supplier_payables','payment_receipt_mgmt',
        'expense_management','inventory_management','stock_adjustment','stock_transfer',
        'low_stock_alerts','multi_branch','daily_sales_report','basic_product_report',
        'monthly_yearly_reports','profit_estimation','excel_export','basic_permissions','manual_data_export'
      ]::text[]),
      ('pro', array[
        'product_management','category_management','customer_management','supplier_management',
        'purchase_management','sales_management','cash_sales','credit_sales','partial_payments',
        'customer_ledger','customer_debt_tracking','supplier_payables','payment_receipt_mgmt',
        'expense_management','inventory_management','stock_adjustment','stock_transfer',
        'low_stock_alerts','multi_branch','advanced_inventory','barcode_support','qr_support',
        'daily_sales_report','basic_product_report','monthly_yearly_reports','customer_statement_pdf',
        'supplier_statement_pdf','sales_analytics','purchase_analytics','branch_reports',
        'profit_loss_report','cash_flow_report','profit_estimation','automated_reports','debt_reminders',
        'excel_export','manual_data_export','basic_permissions','advanced_permissions','audit_logs',
        'backup_restore','priority_support'
      ]::text[])
    ) as expected_plans(plan_id, enabled_features)
  loop
    if not exists (select 1 from public.plans where id=expected.plan_id) then
      raise exception 'FAIL: standard plan % is missing', expected.plan_id;
    end if;

    select count(*) into enabled_count
    from public.plan_features pf
    join public.features f on f.id=pf.feature_id
    where pf.plan_id=expected.plan_id and f.is_active and f.feature_type='boolean';
    if enabled_count <> active_boolean_count then
      raise exception 'FAIL: % has % boolean assignments; expected %',
        expected.plan_id, enabled_count, active_boolean_count;
    end if;

    if exists (
      select 1
      from public.features f
      left join public.plan_features pf on pf.feature_id=f.id and pf.plan_id=expected.plan_id
      where f.is_active and f.feature_type='boolean'
        and pf.is_enabled is distinct from (f.feature_key=any(expected.enabled_features))
    ) then
      raise exception 'FAIL: % boolean feature assignments differ from the advertised tier', expected.plan_id;
    end if;
  end loop;

  if exists (
    select 1
    from (values
      ('starter', 1, 100, 100, 20, 1),
      ('business', 3, 2000, -1, -1, 2),
      ('pro', 10, -1, -1, -1, 5)
    ) as expected(plan_id, max_users, max_products, max_customers, max_suppliers, max_branches)
    join public.plans p on p.id=expected.plan_id
    join public.features f on f.is_active and f.feature_type='limit'
    left join public.plan_feature_limits pfl on pfl.plan_id=p.id and pfl.feature_id=f.id
    where pfl.limit_value is distinct from case f.feature_key
      when 'max_users' then expected.max_users
      when 'max_products' then expected.max_products
      when 'max_customers' then expected.max_customers
      when 'max_suppliers' then expected.max_suppliers
      when 'max_branches' then expected.max_branches
    end
  ) then
    raise exception 'FAIL: a standard plan normalized limit differs from the documented limit';
  end if;

  if exists (
    select 1
    from (values
      ('starter', 1, 100, 100, 20, 1),
      ('business', 3, 2000, -1, -1, 2),
      ('pro', 10, -1, -1, -1, 5)
    ) as expected(plan_id, max_users, max_products, max_customers, max_suppliers, max_branches)
    join public.plans p on p.id=expected.plan_id
    where p.max_users is distinct from expected.max_users
       or p.max_products is distinct from expected.max_products
       or p.max_customers is distinct from expected.max_customers
       or p.max_suppliers is distinct from expected.max_suppliers
       or p.max_branches is distinct from expected.max_branches
  ) then
    raise exception 'FAIL: a standard plan legacy limit differs from the documented limit';
  end if;

  for runtime_plan in
    select * from (values
      ('starter','82000000-0000-4000-8000-000000000001'::uuid,'81000000-0000-4000-8000-000000000001'::uuid),
      ('business','82000000-0000-4000-8000-000000000002'::uuid,'81000000-0000-4000-8000-000000000002'::uuid),
      ('pro','82000000-0000-4000-8000-000000000003'::uuid,'81000000-0000-4000-8000-000000000003'::uuid)
    ) as plans(plan_id,organization_id,user_id)
  loop
    org_id := runtime_plan.organization_id;
    user_id := runtime_plan.user_id;
    perform set_config('request.jwt.claim.sub',user_id::text,true);

    for runtime_feature in
      select f.feature_key, f.feature_type, pf.is_enabled
      from public.features f
      left join public.plan_features pf on pf.feature_id=f.id and pf.plan_id=runtime_plan.plan_id
      where f.is_active
      order by f.feature_key
    loop
      access_result := public.check_organization_feature(org_id,runtime_feature.feature_key);
      if coalesce((access_result->>'is_allowed')::boolean,false)
          is distinct from coalesce(runtime_feature.is_enabled,false)
         or access_result->>'subscription_status' is distinct from 'active' then
        raise exception 'FAIL: runtime entitlement mismatch for plan %, feature %',
          runtime_plan.plan_id,runtime_feature.feature_key;
      end if;

      if runtime_feature.feature_type='limit' then
        expected_limit := public.get_organization_feature_limit(org_id,runtime_feature.feature_key);
        if (expected_limit->>'limit_value')::integer is distinct from (
          select pfl.limit_value from public.plan_feature_limits pfl
          join public.features f on f.id=pfl.feature_id
          where pfl.plan_id=runtime_plan.plan_id and f.feature_key=runtime_feature.feature_key
        ) then
          raise exception 'FAIL: runtime limit lookup mismatch for plan %, limit %',
            runtime_plan.plan_id,runtime_feature.feature_key;
        end if;
        expected_usage := case runtime_feature.feature_key
          when 'max_users' then 1
          when 'max_branches' then 1
          else 0
        end;
        expected_allowed := (expected_limit->>'limit_value')::integer = -1
          or expected_usage < (expected_limit->>'limit_value')::integer;
        limit_decision := public.check_organization_limit(org_id,runtime_feature.feature_key);
        if coalesce((limit_decision->>'is_allowed')::boolean,false) is distinct from expected_allowed
           or (limit_decision->>'current_usage')::integer is distinct from expected_usage then
          raise exception 'FAIL: runtime usage check mismatch for plan %, limit %',
            runtime_plan.plan_id,runtime_feature.feature_key;
        end if;
      end if;
    end loop;

    entitlement_result := public.get_organization_entitlements(org_id);
    if jsonb_array_length(entitlement_result) <> (select count(*) from public.features where is_active) then
      raise exception 'FAIL: runtime entitlement list is incomplete for plan %',runtime_plan.plan_id;
    end if;
  end loop;

  -- A custom plan keeps its own sparse feature assignment and does not inherit
  -- Starter/Business/Pro defaults. Missing feature rows must remain denied.
  perform set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000004',true);
  for runtime_feature in
    select f.feature_key, pf.is_enabled
    from public.features f
    left join public.plan_features pf on pf.feature_id=f.id and pf.plan_id='matrix-custom-test'
    where f.is_active
  loop
    access_result := public.check_organization_feature('82000000-0000-4000-8000-000000000004',runtime_feature.feature_key);
    if coalesce((access_result->>'is_allowed')::boolean,false)
        is distinct from (runtime_feature.feature_key=any(array['cash_sales','max_users']::text[])) then
      raise exception 'FAIL: custom plan inherited or lost feature %',runtime_feature.feature_key;
    end if;
  end loop;
  limit_decision := public.check_organization_limit('82000000-0000-4000-8000-000000000004','max_users');
  if not coalesce((limit_decision->>'is_allowed')::boolean,false)
     or (limit_decision->>'limit_value')::integer <> 2 then
    raise exception 'FAIL: custom plan user limit was not applied independently';
  end if;
  expected_limit := public.get_organization_feature_limit('82000000-0000-4000-8000-000000000004','max_products');
  limit_decision := public.check_organization_limit('82000000-0000-4000-8000-000000000004','max_products');
  if (expected_limit->>'is_configured')::boolean is distinct from true
     or (expected_limit->>'limit_value')::integer <> 50
     or expected_limit->>'source' <> 'legacy_plan_column'
     or coalesce((limit_decision->>'is_allowed')::boolean,true) then
    raise exception 'FAIL: custom plan legacy limit fallback or entitlement denial was incorrect';
  end if;

  -- Expired subscriptions deny otherwise-included features.
  perform set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000006',true);
  access_result := public.check_organization_feature('82000000-0000-4000-8000-000000000005','cash_sales');
  if coalesce((access_result->>'is_allowed')::boolean,true)
     or access_result->>'subscription_status' is distinct from 'expired' then
    raise exception 'FAIL: expired subscription retained plan feature access';
  end if;

  -- A direct membership insert cannot exceed Starter's one-user quota.
  perform set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
  begin
    insert into public.organization_members(organization_id,user_id,role,is_active)
    values('82000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000005','staff',true);
    raise exception 'FAIL: Starter user limit was bypassed by direct membership insert';
  exception when raise_exception then
    if sqlerrm not like 'Plan limit reached:%' then raise; end if;
  end;

  -- A valid owner cannot use a direct entitlement RPC to inspect another org.
  perform set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
  begin
    perform public.get_organization_entitlements('82000000-0000-4000-8000-000000000003');
    raise exception 'FAIL: runtime entitlement RPC accepted a non-member organization';
  exception when raise_exception then
    if sqlerrm <> 'Access denied' then raise; end if;
  end;
end;
$$;

rollback;
