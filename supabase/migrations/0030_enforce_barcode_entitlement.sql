create or replace function public.enforce_barcode_plan_feature()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  access_result jsonb;
begin
  if nullif(btrim(new.barcode), '') is null
     or (tg_op = 'UPDATE' and new.barcode is not distinct from old.barcode) then
    return new;
  end if;

  access_result := public.check_organization_feature(new.organization_id, 'barcode_support');
  if not coalesce((access_result->>'is_allowed')::boolean, false) then
    raise exception 'Barcode support is not available on the current plan';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_products_barcode_plan_feature on public.products;
create trigger trg_products_barcode_plan_feature
  before insert or update of barcode on public.products
  for each row execute function public.enforce_barcode_plan_feature();
