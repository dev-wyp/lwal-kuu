-- Preserve stock availability independently for each branch and allow branch-specific adjustments.
create or replace function public.enforce_branch_stock_nonnegative()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare branch_balance numeric;
begin
  if new.movement_type <> 'sales_out' then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text || ':' || new.branch_id::text || ':' || new.product_id::text, 0));
  select coalesce(sum(quantity), 0) into branch_balance
  from public.stock_movements
  where organization_id = new.organization_id
    and branch_id = new.branch_id
    and product_id = new.product_id;
  if branch_balance + new.quantity < 0 then
    raise exception 'Insufficient stock in the selected branch';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_enforce_branch_stock_nonnegative on public.stock_movements;
create trigger trg_enforce_branch_stock_nonnegative
before insert on public.stock_movements
for each row execute function public.enforce_branch_stock_nonnegative();

create or replace function public.create_stock_adjustment_at_branch(
  p_org_id uuid,
  p_product_id uuid,
  p_quantity_delta numeric,
  p_reason text,
  p_notes text,
  p_branch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_adj_num text;
  v_product public.products%rowtype;
  v_adj_id uuid;
  v_mov_type text;
  v_branch_id uuid;
begin
  if not public.has_org_membership(p_org_id) then raise exception 'Unauthorized'; end if;
  if not public.organization_has_plan_feature(p_org_id, 'stock_adjustment') then raise exception 'Stock adjustment is not available on the current plan'; end if;
  select id into v_branch_id from public.branches
    where organization_id = p_org_id and id = p_branch_id and is_active;
  if v_branch_id is null then raise exception 'Choose an active branch in this organization'; end if;
  select * into v_product from public.products where id = p_product_id and organization_id = p_org_id and is_active;
  if not found then raise exception 'Product not found'; end if;
  if p_quantity_delta = 0 then raise exception 'Quantity delta cannot be zero'; end if;
  if p_quantity_delta < 0 then
    perform pg_advisory_xact_lock(hashtextextended(p_org_id::text || ':' || v_branch_id::text || ':' || p_product_id::text, 0));
    if (select coalesce(sum(quantity), 0) from public.stock_movements where organization_id=p_org_id and branch_id=v_branch_id and product_id=p_product_id) + p_quantity_delta < 0 then
      raise exception 'Adjustment would make branch stock negative';
    end if;
  end if;
  v_adj_num := public.next_document_number(p_org_id, 'stock_adjustment');
  insert into public.stock_adjustments(organization_id, branch_id, adjustment_number, product_id, reason, quantity_delta, unit_cost, notes, created_by)
  values(p_org_id, v_branch_id, v_adj_num, p_product_id, p_reason, p_quantity_delta, v_product.average_cost, p_notes, v_user_id)
  returning id into v_adj_id;
  v_mov_type := case when p_quantity_delta > 0 then 'adjustment_in' else 'adjustment_out' end;
  insert into public.stock_movements(organization_id, branch_id, product_id, movement_type, quantity, unit_cost, reference_type, reference_id, notes, created_by)
  values(p_org_id, v_branch_id, p_product_id, v_mov_type, p_quantity_delta, v_product.average_cost, 'adjustment', v_adj_id, p_notes, v_user_id);
  return jsonb_build_object('success', true, 'adjustment_id', v_adj_id, 'adjustment_number', v_adj_num, 'branch_id', v_branch_id);
end;
$$;
revoke all on function public.create_stock_adjustment_at_branch(uuid,uuid,numeric,text,text,uuid) from public, anon;
grant execute on function public.create_stock_adjustment_at_branch(uuid,uuid,numeric,text,text,uuid) to authenticated;
