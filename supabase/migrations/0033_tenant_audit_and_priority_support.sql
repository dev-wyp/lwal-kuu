-- Tenant audit coverage for common operational records.
-- Keep this migration self-contained for databases that have the entitlement
-- RPCs but are missing the convenience boolean wrapper added in migration 0027.
create or replace function public.organization_has_plan_feature(p_org_id uuid, p_feature_key text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  decision jsonb;
begin
  if public.is_platform_admin() then return true; end if;
  if not public.has_org_membership(p_org_id) then return false; end if;
  decision := public.check_organization_feature(p_org_id, p_feature_key);
  return coalesce((decision->>'is_allowed')::boolean, false);
end;
$$;
revoke all on function public.organization_has_plan_feature(uuid, text) from public, anon;
grant execute on function public.organization_has_plan_feature(uuid, text) to authenticated;

create or replace function public.capture_tenant_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  org_id uuid;
  entity_id uuid;
  before_row jsonb;
  after_row jsonb;
begin
  org_id := coalesce(new.organization_id, old.organization_id);
  entity_id := coalesce(new.id, old.id);
  before_row := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  after_row := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end;
  if tg_op = 'UPDATE' and before_row = after_row then return new; end if;

  insert into public.audit_logs(organization_id, user_id, action, entity_type, entity_id, payload)
  values (
    org_id,
    auth.uid(),
    lower(tg_op) || ':' || tg_table_name,
    tg_table_name,
    entity_id,
    jsonb_build_object('before', before_row, 'after', after_row)
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'products','product_categories','customers','suppliers','sales','sale_items',
    'purchases','purchase_items','payments','supplier_payments','expenses','stock_adjustments'
  ] loop
    execute format('drop trigger if exists trg_audit_%I on public.%I', table_name, table_name);
    execute format(
      'create trigger trg_audit_%I after insert or update or delete on public.%I for each row execute function public.capture_tenant_audit_log()',
      table_name, table_name
    );
  end loop;
end;
$$;

-- A tenant can create and view its priority support requests only while entitled.
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  subject text not null check (length(btrim(subject)) between 1 and 180),
  description text not null check (length(btrim(description)) between 1 and 10000),
  status text not null default 'open' check (status in ('open','in_progress','resolved','closed')),
  priority text not null default 'priority' check (priority in ('normal','priority')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_support_tickets_org_created
  on public.support_tickets(organization_id, created_at desc);
alter table public.support_tickets enable row level security;
drop policy if exists support_tickets_tenant_read on public.support_tickets;
create policy support_tickets_tenant_read on public.support_tickets for select
  using (public.has_org_membership(organization_id) and public.organization_has_plan_feature(organization_id, 'priority_support'));
drop policy if exists support_tickets_tenant_create on public.support_tickets;
create policy support_tickets_tenant_create on public.support_tickets for insert
  with check (
    public.has_org_membership(organization_id)
    and created_by = auth.uid()
    and public.organization_has_plan_feature(organization_id, 'priority_support')
  );
drop policy if exists support_tickets_platform_admin on public.support_tickets;
create policy support_tickets_platform_admin on public.support_tickets for all
  using (public.is_platform_admin()) with check (public.is_platform_admin());
revoke all on public.support_tickets from anon;
grant select, insert, update on public.support_tickets to authenticated;
