-- Tenant/RLS and plan-entitlement assertions for the checked-in organization_id contract.
-- Run only on a disposable database with migrations 0001–0047 applied.
begin;

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('51000000-0000-4000-8000-000000000001','authenticated','authenticated','tenant-a-owner@example.invalid','',now(),now(),now()),
  ('51000000-0000-4000-8000-000000000002','authenticated','authenticated','tenant-b-owner@example.invalid','',now(),now(),now()),
  ('51000000-0000-4000-8000-000000000003','authenticated','authenticated','tenant-a-staff@example.invalid','',now(),now(),now()),
  ('51000000-0000-4000-8000-000000000004','authenticated','authenticated','tenant-c-staff@example.invalid','',now(),now(),now());

insert into public.organizations (id,name,slug)
values
  ('52000000-0000-4000-8000-000000000001','Tenant A','tenant-a-security-test'),
  ('52000000-0000-4000-8000-000000000002','Tenant B','tenant-b-security-test'),
  ('52000000-0000-4000-8000-000000000003','Tenant C','tenant-c-security-test');

insert into public.subscriptions(organization_id,plan_id,status,billing_cycle)
values
  ('52000000-0000-4000-8000-000000000001','business','active','monthly'),
  ('52000000-0000-4000-8000-000000000002','starter','active','monthly'),
  ('52000000-0000-4000-8000-000000000003','pro','active','monthly');

insert into public.organization_members (organization_id,user_id,role,is_active)
values
  ('52000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000001','owner',true),
  ('52000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000003','staff',true),
  ('52000000-0000-4000-8000-000000000002','51000000-0000-4000-8000-000000000002','owner',true),
  ('52000000-0000-4000-8000-000000000003','51000000-0000-4000-8000-000000000004','staff',true);
insert into public.organization_role_permissions(organization_id,role,permission_key,can_view,can_create,can_update,can_delete)
values
  ('52000000-0000-4000-8000-000000000003','staff','customers',false,false,false,false),
  ('52000000-0000-4000-8000-000000000003','staff','suppliers',false,false,false,false);

insert into public.customers (id,organization_id,name)
values
  ('53000000-0000-4000-8000-000000000001','52000000-0000-4000-8000-000000000001','Customer A'),
  ('53000000-0000-4000-8000-000000000002','52000000-0000-4000-8000-000000000002','Customer B'),
  ('53000000-0000-4000-8000-000000000003','52000000-0000-4000-8000-000000000003','Customer C');
insert into public.payments(id,organization_id,customer_id,payment_number,amount)
values
  ('56000000-0000-4000-8000-000000000001','52000000-0000-4000-8000-000000000001','53000000-0000-4000-8000-000000000001','SEC-A-REC-1',5),
  ('56000000-0000-4000-8000-000000000002','52000000-0000-4000-8000-000000000002','53000000-0000-4000-8000-000000000002','SEC-B-REC-1',5),
  ('56000000-0000-4000-8000-000000000003','52000000-0000-4000-8000-000000000003','53000000-0000-4000-8000-000000000003','SEC-C-REC-1',5);
insert into public.payment_allocations(id,organization_id,payment_id,amount)
values
  ('57000000-0000-4000-8000-000000000001','52000000-0000-4000-8000-000000000001','56000000-0000-4000-8000-000000000001',5),
  ('57000000-0000-4000-8000-000000000002','52000000-0000-4000-8000-000000000002','56000000-0000-4000-8000-000000000002',5);
insert into public.suppliers (id,organization_id,name)
values
  ('54000000-0000-4000-8000-000000000001','52000000-0000-4000-8000-000000000001','Supplier A'),
  ('54000000-0000-4000-8000-000000000002','52000000-0000-4000-8000-000000000002','Supplier B');
insert into public.supplier_payments(id,organization_id,supplier_id,payment_number,amount,payment_method)
values
  ('55000000-0000-4000-8000-000000000001','52000000-0000-4000-8000-000000000001','54000000-0000-4000-8000-000000000001','SEC-A-PAY-1',5,'cash'),
  ('55000000-0000-4000-8000-000000000002','52000000-0000-4000-8000-000000000002','54000000-0000-4000-8000-000000000002','SEC-B-PAY-1',5,'cash'),
  ('55000000-0000-4000-8000-000000000003','52000000-0000-4000-8000-000000000003','54000000-0000-4000-8000-000000000003','SEC-C-PAY-1',5,'cash');

set local role authenticated;
select set_config('request.jwt.claim.sub','51000000-0000-4000-8000-000000000001',true);

do $$
begin
  if not public.has_org_membership('52000000-0000-4000-8000-000000000001') then
    raise exception 'FAIL: member cannot access their own organization';
  end if;
  if public.has_org_membership('52000000-0000-4000-8000-000000000002') then
    raise exception 'FAIL: member is treated as belonging to a different organization';
  end if;
  if (select count(*) from public.customers) <> 1 or exists (select 1 from public.customers where name='Customer B') then
    raise exception 'FAIL: RLS exposed another organization customer';
  end if;
  if (select count(*) from public.organizations) <> 1 or exists (select 1 from public.organizations where slug='tenant-b-security-test') then
    raise exception 'FAIL: RLS exposed another organization record';
  end if;
  if (select count(*) from public.customer_balances_summary) <> 1 then
    raise exception 'FAIL: Business plan cannot read its customer balance summary';
  end if;
  if (select count(*) from public.supplier_balances_summary) <> 1 then
    raise exception 'FAIL: Business plan cannot read its supplier payable summary';
  end if;
  if (select count(*) from public.supplier_payments) <> 1 then
    raise exception 'FAIL: Business plan cannot read its own supplier payment rows';
  end if;
  if (select count(*) from public.payments) <> 1 then
    raise exception 'FAIL: Business plan cannot read its own customer payment rows';
  end if;
  if (select count(*) from public.payment_allocations) <> 1 then
    raise exception 'FAIL: Business plan cannot read its own customer payment allocations';
  end if;
  perform * from public.get_customer_statement(
    '52000000-0000-4000-8000-000000000001','53000000-0000-4000-8000-000000000001',null,null
  );
  begin
    perform * from public.get_customer_statement(
      '52000000-0000-4000-8000-000000000001','53000000-0000-4000-8000-000000000002',null,null
    );
    raise exception 'FAIL: customer statement accepted another organization customer';
  exception when raise_exception then
    if sqlerrm <> 'Customer does not belong to this organization' then raise; end if;
  end;
  if has_table_privilege('authenticated','public.stock_movements','INSERT')
     or has_table_privilege('authenticated','public.payments','INSERT')
     or has_table_privilege('authenticated','public.supplier_payments','INSERT') then
    raise exception 'FAIL: authenticated clients can write to posted ledgers';
  end if;
  if has_column_privilege('authenticated','public.profiles','is_platform_admin','UPDATE') then
    raise exception 'FAIL: authenticated clients can change platform administrator status';
  end if;
  if has_table_privilege('authenticated','public.organization_members','INSERT') then
    raise exception 'FAIL: authenticated clients can directly create memberships';
  end if;
end;
$$;

-- Direct view and RPC access must enforce the Starter plan even when callers
-- bypass React FeatureGate and invoke database objects themselves.
select set_config('request.jwt.claim.sub','51000000-0000-4000-8000-000000000002',true);
do $$
begin
  if (select count(*) from public.customer_balances_summary) <> 0 then
    raise exception 'FAIL: Starter can read customer ledger summary directly';
  end if;
  if (select count(*) from public.supplier_balances_summary) <> 0 then
    raise exception 'FAIL: Starter can read supplier payable summary directly';
  end if;
  if (select count(*) from public.supplier_payments) <> 0 then
    raise exception 'FAIL: Starter can read supplier payment rows directly';
  end if;
  if (select count(*) from public.payments) <> 0 then
    raise exception 'FAIL: Starter can read customer payment rows directly';
  end if;
  if (select count(*) from public.payment_allocations) <> 0 then
    raise exception 'FAIL: Starter can read customer payment allocations directly';
  end if;
  begin
    perform * from public.get_customer_statement(
      '52000000-0000-4000-8000-000000000002','53000000-0000-4000-8000-000000000002',null,null
    );
    raise exception 'FAIL: Starter can call customer statement RPC';
  exception when raise_exception then
    if sqlerrm <> 'Customer ledger is not available on the current plan' then raise; end if;
  end;
end;
$$;

-- Staff can perform the normal customer workflow in their organization, but not
-- create data in another tenant or create expenses by bypassing role permissions.
select set_config('request.jwt.claim.sub','51000000-0000-4000-8000-000000000003',true);
do $$
begin
  if not public.has_org_permission('52000000-0000-4000-8000-000000000001','customers','create') then
    raise exception 'FAIL: staff lost the expected customer create permission';
  end if;
  if public.has_org_permission('52000000-0000-4000-8000-000000000001','expenses','create') then
    raise exception 'FAIL: staff can create expenses without permission';
  end if;
  begin
    insert into public.customers (organization_id,name)
    values ('52000000-0000-4000-8000-000000000002','Cross-tenant customer');
    raise exception 'FAIL: cross-tenant insert unexpectedly succeeded';
  exception when insufficient_privilege then
    null;
  end;
  insert into public.customers (organization_id,name)
  values ('52000000-0000-4000-8000-000000000001','Staff-created customer');
  begin
    insert into public.expenses (organization_id,amount,title)
    values ('52000000-0000-4000-8000-000000000001',10,'Unauthorized staff expense');
    raise exception 'FAIL: staff expense insert unexpectedly succeeded';
  exception when raise_exception then
    if sqlerrm <> 'Your organization role does not allow this action' then raise; end if;
  end;
end;
$$;

-- SECURITY DEFINER statement reads must honor advanced customer-view roles,
-- not only membership and plan entitlement.
select set_config('request.jwt.claim.sub','51000000-0000-4000-8000-000000000004',true);
do $$
begin
  if public.has_org_permission('52000000-0000-4000-8000-000000000003','customers','view') then
    raise exception 'FAIL: fixture expected Pro staff customer-view permission to be denied';
  end if;
  if (select count(*) from public.supplier_payments) <> 0 then
    raise exception 'FAIL: supplier payment read bypassed advanced supplier-view role permission';
  end if;
  begin
    perform * from public.get_customer_statement(
      '52000000-0000-4000-8000-000000000003','53000000-0000-4000-8000-000000000003',null,null
    );
    raise exception 'FAIL: customer statement RPC bypassed advanced role permission';
  exception when raise_exception then
    if sqlerrm <> 'Your organization role does not allow customer ledger access' then raise; end if;
  end;
end;
$$;

rollback;
