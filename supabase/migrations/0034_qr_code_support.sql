alter table public.products add column if not exists qr_code text;

create or replace function public.enforce_product_code_entitlement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  field_name text := tg_argv[1];
  feature_key text := tg_argv[0];
  current_value text;
  old_value text;
  access_result jsonb;
begin
  current_value := nullif(btrim(to_jsonb(new)->>field_name), '');
  if tg_op = 'UPDATE' then
    old_value := nullif(btrim(to_jsonb(old)->>field_name), '');
    if current_value is not distinct from old_value then return new; end if;
  end if;
  if current_value is null then return new; end if;

  access_result := public.check_organization_feature(new.organization_id, feature_key);
  if not coalesce((access_result->>'is_allowed')::boolean, false) then
    raise exception '% is not available on the current plan', feature_key;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_products_qr_plan_feature on public.products;
create trigger trg_products_qr_plan_feature
  before insert or update of qr_code on public.products
  for each row execute function public.enforce_product_code_entitlement('qr_support','qr_code');
