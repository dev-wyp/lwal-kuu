begin;

-- Create the order and all its lines as one transaction. A failure in any
-- validation or insert rolls back the document number, header, and every line.
create or replace function public.create_purchase_order(
  p_org_id uuid,
  p_supplier_id uuid,
  p_branch_id uuid,
  p_purchase_date date,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_branch_id uuid := p_branch_id;
  v_purchase_id uuid := gen_random_uuid();
  v_purchase_number text;
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(12,2);
  v_unit_cost numeric(14,2);
  v_total numeric(14,2) := 0;
  v_line_total numeric(14,2);
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id, 'purchases', 'create') then
    raise exception 'You do not have permission to create purchase orders';
  end if;
  if p_supplier_id is null or not exists (
    select 1 from public.suppliers s
    where s.id=p_supplier_id and s.organization_id=p_org_id and s.is_active
  ) then raise exception 'Choose an active supplier in this organization'; end if;
  if p_purchase_date is null then raise exception 'Purchase date is required'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Purchase order requires at least one item';
  end if;

  if v_branch_id is null then
    select b.id into v_branch_id from public.branches b
    where b.organization_id=p_org_id and b.is_active
    order by b.is_default desc, b.created_at, b.id limit 1;
  end if;
  if v_branch_id is null or not exists (
    select 1 from public.branches b
    where b.id=v_branch_id and b.organization_id=p_org_id and b.is_active
  ) then raise exception 'Choose an active branch in this organization'; end if;

  -- Validate all lines and calculate the same rounded totals that will be stored.
  for v_item in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(v_item)<>'object'
       or nullif(v_item->>'product_id','') is null
       or nullif(v_item->>'quantity','') is null
       or nullif(v_item->>'unit_cost','') is null then
      raise exception 'Each purchase line needs a product, quantity, and unit cost';
    end if;
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::numeric;
    v_unit_cost := (v_item->>'unit_cost')::numeric;
    if v_quantity::text in ('NaN','Infinity','-Infinity') or v_quantity<=0 then
      raise exception 'Purchase quantities must be finite and greater than zero';
    end if;
    if v_unit_cost::text in ('NaN','Infinity','-Infinity') or v_unit_cost<0 then
      raise exception 'Purchase unit costs must be finite and cannot be negative';
    end if;
    if not exists (
      select 1 from public.products p
      where p.id=v_product_id and p.organization_id=p_org_id and p.is_active
    ) then raise exception 'A selected product is missing, inactive, or belongs to another organization'; end if;
    v_line_total := round(v_quantity*v_unit_cost,2);
    v_total := v_total+v_line_total;
  end loop;

  v_purchase_number := public.next_document_number(p_org_id,'purchase');
  insert into public.purchases(
    id,organization_id,supplier_id,branch_id,purchase_number,purchase_date,status,
    subtotal,total,total_amount,created_by
  ) values (
    v_purchase_id,p_org_id,p_supplier_id,v_branch_id,v_purchase_number,p_purchase_date,'ordered',
    v_total,v_total,v_total,v_user_id
  );

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::numeric;
    v_unit_cost := (v_item->>'unit_cost')::numeric;
    insert into public.purchase_items(
      organization_id,purchase_id,product_id,quantity,unit_cost,total_cost
    ) values (
      p_org_id,v_purchase_id,v_product_id,v_quantity,v_unit_cost,round(v_quantity*v_unit_cost,2)
    );
  end loop;

  return jsonb_build_object(
    'success',true,
    'purchase_id',v_purchase_id,
    'purchase_number',v_purchase_number,
    'total_amount',v_total
  );
end;
$$;

revoke all on function public.create_purchase_order(uuid,uuid,uuid,date,jsonb) from public,anon;
grant execute on function public.create_purchase_order(uuid,uuid,uuid,date,jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
