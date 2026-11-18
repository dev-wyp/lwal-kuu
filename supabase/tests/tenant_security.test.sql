-- Tenant/RLS assertions for the checked-in organization_id migration contract.
-- Run only on a disposable database with the full migration chain applied.
begin;

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('51000000-0000-4000-8000-000000000001','authenticated','authenticated','tenant-a-owner@example.invalid','',now(),now(),now()),
  ('51000000-0000-4000-8000-000000000002','authenticated','authenticated','tenant-b-owner@example.invalid','',now(),now(),now()),
  ('51000000-0000-4000-8000-000000000003','authenticated','authenticated','tenant-a-staff@example.invalid','',now(),now(),now());

insert into public.organizations (id,name,slug)
values
  ('52000000-0000-4000-8000-000000000001','Tenant A','tenant-a-security-test'),
  ('52000000-0000-4000-8000-000000000002','Tenant B','tenant-b-security-test');

insert into public.organization_members (organization_id,user_id,role,is_active)
values
  ('52000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000001','owner',true),
  ('52000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000003','staff',true),
  ('52000000-0000-4000-8000-000000000002','51000000-0000-4000-8000-000000000002','owner',true);

insert into public.customers (organization_id,name)
values
  ('52000000-0000-4000-8000-000000000001','Customer A'),
  ('52000000-0000-4000-8000-000000000002','Customer B');

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

rollback;
