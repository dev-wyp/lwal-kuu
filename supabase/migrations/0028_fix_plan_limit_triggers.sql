-- Separate organization member bootstrap fields from the generic tenant limit trigger.
-- PostgreSQL evaluates NEW against the trigger's table row, so a shared trigger
-- must never access fields that do not exist on every attached table.

create or replace function public.enforce_plan_entitlements()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  org_id uuid;
  feature_key text;
  usage_key text;
  check_result jsonb;
  should_enforce boolean;
begin
  org_id := new.organization_id;
  feature_key := tg_argv[0];
  usage_key := tg_argv[1];
  should_enforce := tg_op = 'INSERT'
    or (tg_op = 'UPDATE' and coalesce(old.is_active, true) = false and coalesce(new.is_active, true));

  if not should_enforce then return new; end if;

  perform pg_advisory_xact_lock(hashtextextended(org_id::text || ':' || usage_key, 0));
  check_result := public.check_organization_feature(org_id, feature_key);
  if not coalesce((check_result->>'is_allowed')::boolean, false) then
    raise exception 'This feature is not available: %', check_result->>'reason';
  end if;

  check_result := public.check_organization_limit(org_id, usage_key);
  if not coalesce((check_result->>'is_allowed')::boolean, false) then
    raise exception 'Plan limit reached: %', check_result->>'reason';
  end if;
  return new;
end;
$$;

create or replace function public.enforce_user_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  org_id uuid;
  check_result jsonb;
begin
  org_id := new.organization_id;

  -- Organization creation inserts its owner before initializing the trial.
  if tg_op = 'INSERT'
     and not exists (select 1 from public.subscriptions where organization_id = org_id)
     and not exists (select 1 from public.organization_members where organization_id = org_id and is_active)
     and new.user_id = auth.uid()
     and new.role = 'owner' then
    return new;
  end if;

  if tg_op = 'UPDATE' and (coalesce(old.is_active, true) or not coalesce(new.is_active, false)) then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(org_id::text || ':max_users', 0));
  check_result := public.check_organization_feature(org_id, 'max_users');
  if not coalesce((check_result->>'is_allowed')::boolean, false) then
    raise exception 'User feature is not available: %', check_result->>'reason';
  end if;
  check_result := public.check_organization_limit(org_id, 'max_users');
  if not coalesce((check_result->>'is_allowed')::boolean, false) then
    raise exception 'User limit reached: %', check_result->>'reason';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_product_plan_limit on public.products;
create trigger trg_enforce_product_plan_limit
  before insert or update of is_active on public.products
  for each row execute function public.enforce_plan_entitlements('product_management', 'max_products');

drop trigger if exists trg_enforce_user_plan_limit on public.organization_members;
create trigger trg_enforce_user_plan_limit
  before insert or update of is_active on public.organization_members
  for each row execute function public.enforce_user_plan_limit();

drop trigger if exists trg_enforce_customer_plan_limit on public.customers;
create trigger trg_enforce_customer_plan_limit
  before insert or update of is_active on public.customers
  for each row execute function public.enforce_plan_entitlements('customer_management', 'max_customers');

drop trigger if exists trg_enforce_supplier_plan_limit on public.suppliers;
create trigger trg_enforce_supplier_plan_limit
  before insert or update of is_active on public.suppliers
  for each row execute function public.enforce_plan_entitlements('supplier_management', 'max_suppliers');
