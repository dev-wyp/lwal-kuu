-- Close tenant write paths and make role permissions apply on every plan.
-- Business entities remain writable through RLS; posted ledgers are RPC-only.

create or replace function public.has_org_permission(p_org_id uuid, p_permission text, p_action text default 'view')
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  member_role text;
  allowed boolean;
begin
  if auth.role() = 'service_role' then return true; end if;
  if auth.uid() is null then return false; end if;
  if public.is_platform_admin() then return true; end if;
  if p_action not in ('view','create','update','delete') then return false; end if;

  select role into member_role
  from public.organization_members
  where organization_id = p_org_id and user_id = auth.uid() and is_active;
  if member_role is null then return false; end if;
  if member_role in ('owner','admin') then return true; end if;

  -- Custom permissions only apply when the organization's plan includes them.
  if public.organization_has_plan_feature(p_org_id, 'advanced_permissions') then
    select case p_action
      when 'view' then can_view
      when 'create' then can_create
      when 'update' then can_update
      when 'delete' then can_delete
    end into allowed
    from public.organization_role_permissions
    where organization_id = p_org_id and role = member_role and permission_key = p_permission;
    if found then return coalesce(allowed, false); end if;
  end if;

  -- Safe baseline permissions also apply to plans without custom role settings.
  if member_role = 'staff' then
    if p_action = 'view' then return p_permission in ('products','customers','sales','inventory'); end if;
    return p_permission in ('sales','customers') and p_action in ('create','update');
  end if;
  if member_role = 'manager' then
    return p_permission in ('products','customers','suppliers','sales','purchases','inventory','expenses')
      and p_action <> 'delete';
  end if;
  return false;
end;
$$;
revoke all on function public.has_org_permission(uuid,text,text) from public, anon;
grant execute on function public.has_org_permission(uuid,text,text) to authenticated, service_role;

-- SECURITY DEFINER RPCs bypass table grants and RLS, so retain role checks in
-- triggers for every operational write path as well.
create or replace function public.enforce_advanced_role_permission()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  permission_key text;
  action_key text;
  org_id uuid;
begin
  org_id := coalesce(new.organization_id, old.organization_id);
  permission_key := case tg_table_name
    when 'products' then 'products' when 'product_categories' then 'products'
    when 'customers' then 'customers' when 'suppliers' then 'suppliers'
    when 'sales' then 'sales' when 'sale_items' then 'sales' when 'payments' then 'sales' when 'payment_allocations' then 'sales'
    when 'purchases' then 'purchases' when 'purchase_items' then 'purchases' when 'supplier_payments' then 'purchases'
    when 'stock_adjustments' then 'inventory' when 'stock_movements' then 'inventory'
    when 'branches' then 'inventory' when 'stock_transfers' then 'inventory' when 'stock_transfer_items' then 'inventory'
    when 'expenses' then 'expenses' when 'expense_categories' then 'expenses'
    else null end;
  if tg_table_name = 'stock_movements' then
    permission_key := case new.movement_type
      when 'sales_out' then 'sales' when 'sale_reversal' then 'sales' when 'customer_return' then 'sales'
      when 'purchase_in' then 'purchases' when 'supplier_return' then 'purchases'
      else 'inventory' end;
  end if;
  if permission_key is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  action_key := case tg_op when 'INSERT' then 'create' when 'UPDATE' then 'update' when 'DELETE' then 'delete' else 'view' end;
  if not public.has_org_permission(org_id, permission_key, action_key) then
    raise exception 'Your organization role does not allow this action';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'products','product_categories','customers','suppliers','sales','sale_items','payments','payment_allocations',
    'purchases','purchase_items','supplier_payments','stock_adjustments','stock_movements','expenses','expense_categories',
    'branches','stock_transfers','stock_transfer_items'
  ] loop
    execute format('drop trigger if exists trg_advanced_role_permission on public.%I', table_name);
    execute format('create trigger trg_advanced_role_permission before insert or update or delete on public.%I for each row execute function public.enforce_advanced_role_permission()', table_name);
  end loop;
end;
$$;

-- Restrictive policies compose with the existing tenant membership policies.
do $$
declare item record;
begin
  for item in select * from (values
    ('products','products'),('product_categories','products'),('customers','customers'),('suppliers','suppliers'),
    ('sales','sales'),('sale_items','sales'),('purchases','purchases'),('purchase_items','purchases'),
    ('expenses','expenses'),('expense_categories','expenses'),('stock_adjustments','inventory'),('stock_movements','inventory'),
    ('branches','inventory'),('stock_transfers','inventory'),('stock_transfer_items','inventory')
  ) as scoped(table_name, permission_key) loop
    execute format('drop policy if exists tenant_role_insert on public.%I', item.table_name);
    execute format('drop policy if exists tenant_role_update on public.%I', item.table_name);
    execute format('drop policy if exists tenant_role_delete on public.%I', item.table_name);
    execute format(
      'create policy tenant_role_insert on public.%I as restrictive for insert to authenticated with check (public.has_org_permission(organization_id,%L,''create''))',
      item.table_name, item.permission_key);
    execute format(
      'create policy tenant_role_update on public.%I as restrictive for update to authenticated using (public.has_org_permission(organization_id,%L,''update'')) with check (public.has_org_permission(organization_id,%L,''update''))',
      item.table_name, item.permission_key, item.permission_key);
    execute format(
      'create policy tenant_role_delete on public.%I as restrictive for delete to authenticated using (public.has_org_permission(organization_id,%L,''delete''))',
      item.table_name, item.permission_key);
  end loop;
end;
$$;

-- Membership changes and organization provisioning must remain atomic and owner-controlled.
drop policy if exists "User can insert themselves as owner" on public.organization_members;
drop policy if exists "Owners and Admins can manage members" on public.organization_members;
create policy organization_members_admin_write on public.organization_members for all to authenticated
  using (public.is_org_admin_or_owner(organization_id))
  with check (public.is_org_admin_or_owner(organization_id));
revoke insert, update, delete on public.organization_members from anon, authenticated;

-- The SECURITY DEFINER onboarding RPC is the only client path that provisions a tenant.
drop policy if exists "Authenticated users can create organizations" on public.organizations;
drop policy if exists "Authenticated users can create organization" on public.organizations;
revoke insert on public.organizations from anon, authenticated;
revoke all on function public.create_organization_with_owner(text,text,text,text,text) from public, anon;
grant execute on function public.create_organization_with_owner(text,text,text,text,text) to authenticated;

-- Migration 0012 accidentally allowed every authenticated user to list every tenant.
drop policy if exists "Members can view own organization" on public.organizations;
drop policy if exists "Members can view their organizations" on public.organizations;
create policy organizations_member_read on public.organizations for select to authenticated
  using (public.has_org_membership(id) or public.is_platform_admin());

-- Keep provisioning atomic: a failed trial/subscription setup must roll back the tenant.
create or replace function public.create_organization_with_owner(
  p_name text,
  p_slug text,
  p_plan_id text default 'starter',
  p_phone text default null,
  p_address text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_org_id uuid;
  v_org record;
begin
  if v_user_id is null then raise exception 'Unauthorized: user must be authenticated'; end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 160 then raise exception 'Organization name is invalid'; end if;
  if p_slug is null or p_slug !~ '^[a-z0-9-]{2,80}$' then raise exception 'Organization identifier is invalid'; end if;

  insert into public.organizations (name, slug, currency, timezone, is_active)
  values (btrim(p_name), btrim(p_slug), 'MMK', 'Asia/Yangon', true)
  returning id into v_org_id;
  insert into public.organization_members (organization_id, user_id, role, is_active)
  values (v_org_id, v_user_id, 'owner', true);
  insert into public.organization_settings (
    organization_id, currency_code, currency_symbol, timezone, phone, address, costing_method, low_stock_threshold_default
  ) values (v_org_id, 'MMK', 'Ks', 'Asia/Yangon', p_phone, p_address, 'weighted_average', 5);
  perform public.initialize_organization_trial(v_org_id, p_plan_id);
  insert into public.units (organization_id, code, name, precision)
  values
    (v_org_id, 'pcs', 'Pieces (ခု)', 0),
    (v_org_id, 'box', 'Box (ဖာ)', 0),
    (v_org_id, 'pack', 'Packet (ထုပ်)', 0),
    (v_org_id, 'dozen', 'Dozen (ဒါဇင်)', 0)
  on conflict do nothing;
  select id, name, slug, currency, timezone, is_active into v_org
  from public.organizations where id = v_org_id;
  return to_jsonb(v_org);
end;
$$;
revoke all on function public.create_organization_with_owner(text,text,text,text,text) from public, anon;
grant execute on function public.create_organization_with_owner(text,text,text,text,text) to authenticated;

-- Never allow a user to grant themselves platform administrator status.
revoke update on public.profiles from anon, authenticated;
grant update (full_name, phone_number, avatar_url) on public.profiles to authenticated;

-- These tables are immutable financial/inventory ledgers. Mutations go through validated RPCs.
revoke insert, update, delete on public.stock_movements, public.stock_adjustments,
  public.payments, public.payment_allocations, public.supplier_payments, public.audit_logs
  from anon, authenticated;

-- RPCs used by the client after direct ledger writes are revoked.
revoke all on function public.next_document_number(uuid,text) from public, anon;
grant execute on function public.next_document_number(uuid,text) to authenticated;
revoke all on function public.create_stock_adjustment(uuid,uuid,numeric,text,text) from public, anon;
grant execute on function public.create_stock_adjustment(uuid,uuid,numeric,text,text) to authenticated;
revoke all on function public.receive_purchase(uuid,uuid,numeric,text) from public, anon;
grant execute on function public.receive_purchase(uuid,uuid,numeric,text) to authenticated;
revoke all on function public.confirm_sale(uuid,uuid,text,numeric,text) from public, anon;
grant execute on function public.confirm_sale(uuid,uuid,text,numeric,text) to authenticated;
revoke all on function public.void_or_reverse_sale(uuid,uuid,text) from public, anon;
grant execute on function public.void_or_reverse_sale(uuid,uuid,text) to authenticated;
revoke all on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) from public, anon;
grant execute on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) to authenticated;

notify pgrst, 'reload schema';
