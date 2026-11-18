create table if not exists public.organization_role_permissions (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  role text not null check (role in ('manager','staff')),
  permission_key text not null check (permission_key in ('products','customers','suppliers','sales','purchases','inventory','expenses')),
  can_view boolean not null default true,
  can_create boolean not null default true,
  can_update boolean not null default true,
  can_delete boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (organization_id, role, permission_key)
);
alter table public.organization_role_permissions enable row level security;
drop policy if exists organization_role_permissions_admin_access on public.organization_role_permissions;
create policy organization_role_permissions_admin_access on public.organization_role_permissions for all
  using (public.is_org_admin_or_owner(organization_id) and public.organization_has_plan_feature(organization_id,'advanced_permissions'))
  with check (public.is_org_admin_or_owner(organization_id) and public.organization_has_plan_feature(organization_id,'advanced_permissions'));
grant select, insert, update, delete on public.organization_role_permissions to authenticated;

create or replace function public.has_org_permission(p_org_id uuid, p_permission text, p_action text default 'view')
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  member_role text;
  configured boolean;
  allowed boolean;
begin
  if auth.uid() is null or public.is_platform_admin() then return true; end if;
  select role into member_role from public.organization_members
    where organization_id=p_org_id and user_id=auth.uid() and is_active;
  if member_role is null then return false; end if;
  if member_role in ('owner','admin') then return true; end if;
  if not public.organization_has_plan_feature(p_org_id,'advanced_permissions') then return true; end if;
  select case p_action when 'view' then can_view when 'create' then can_create when 'update' then can_update when 'delete' then can_delete else false end
    into allowed from public.organization_role_permissions
    where organization_id=p_org_id and role=member_role and permission_key=p_permission;
  if found then return coalesce(allowed,false); end if;
  if member_role='staff' then return p_permission in ('sales','customers') and p_action in ('view','create','update'); end if;
  if member_role='manager' then return p_permission in ('products','customers','suppliers','sales','purchases','inventory','expenses') and p_action <> 'delete'; end if;
  return false;
end;
$$;
revoke all on function public.has_org_permission(uuid,text,text) from public, anon;
grant execute on function public.has_org_permission(uuid,text,text) to authenticated;

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
    when 'sales' then 'sales' when 'sale_items' then 'sales' when 'payments' then 'sales'
    when 'purchases' then 'purchases' when 'purchase_items' then 'purchases' when 'supplier_payments' then 'purchases'
    when 'stock_adjustments' then 'inventory' when 'stock_movements' then 'inventory'
    when 'expenses' then 'expenses' else null end;
  if permission_key is null or not public.organization_has_plan_feature(org_id,'advanced_permissions') then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  action_key := case tg_op when 'INSERT' then 'create' when 'UPDATE' then 'update' when 'DELETE' then 'delete' else 'view' end;
  if not public.has_org_permission(org_id,permission_key,action_key) then raise exception 'Your organization role does not allow this action'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
do $$
declare table_name text;
begin
  foreach table_name in array array['products','product_categories','customers','suppliers','sales','sale_items','payments','purchases','purchase_items','supplier_payments','stock_adjustments','stock_movements','expenses'] loop
    execute format('drop trigger if exists trg_advanced_role_permission on public.%I',table_name);
    execute format('create trigger trg_advanced_role_permission before insert or update or delete on public.%I for each row execute function public.enforce_advanced_role_permission()',table_name);
  end loop;
end;
$$;
