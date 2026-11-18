create or replace function public.export_organization_backup(p_org_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  table_name text;
  rows_json jsonb;
  backup_data jsonb := jsonb_build_object('format_version', 1, 'organization_id', p_org_id, 'created_at', now(), 'tables', '{}'::jsonb);
  table_names text[] := array[
    'branches','product_categories','units','expense_categories','products','customers','suppliers',
    'purchases','purchase_items','supplier_payments','sales','sale_items','payments','payment_allocations',
    'expenses','stock_adjustments','stock_transfers','stock_transfer_items','stock_movements'
  ];
begin
  if not public.is_org_admin_or_owner(p_org_id) then raise exception 'Organization administrator access required'; end if;
  if not public.organization_has_plan_feature(p_org_id, 'backup_restore') then raise exception 'Backup and restore is not available on the current plan'; end if;
  foreach table_name in array table_names loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), ''[]''::jsonb) from public.%I t where t.organization_id = $1', table_name)
      into rows_json using p_org_id;
    backup_data := jsonb_set(backup_data, array['tables', table_name], rows_json, true);
  end loop;
  return backup_data;
end;
$$;
alter table public.stock_transfer_items add column if not exists created_at timestamptz not null default now();
revoke all on function public.export_organization_backup(uuid) from public, anon;
grant execute on function public.export_organization_backup(uuid) to authenticated;

create or replace function public.restore_organization_backup(p_org_id uuid, p_backup jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  table_name text;
  column_updates text;
  restored_count integer := 0;
  table_count integer;
  table_names text[] := array[
    'branches','product_categories','units','expense_categories','products','customers','suppliers',
    'purchases','purchase_items','supplier_payments','sales','sale_items','payments','payment_allocations',
    'expenses','stock_adjustments','stock_transfers','stock_transfer_items','stock_movements'
  ];
begin
  if not public.is_org_admin_or_owner(p_org_id) then raise exception 'Organization administrator access required'; end if;
  if not public.organization_has_plan_feature(p_org_id, 'backup_restore') then raise exception 'Backup and restore is not available on the current plan'; end if;
  if coalesce(jsonb_typeof(p_backup) <> 'object', true)
     or coalesce((p_backup->>'format_version')::integer, 0) <> 1
     or coalesce((p_backup->>'organization_id')::uuid <> p_org_id, true)
     or coalesce(jsonb_typeof(p_backup->'tables') <> 'object', true) then
    raise exception 'Backup file is invalid or belongs to another organization';
  end if;

  -- Validate all cross-table references against records in this tenant or this backup.
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') r where r->>'unit_id' is not null
      and not exists (select 1 from public.units u where u.id=(r->>'unit_id')::uuid and u.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'units') u where u->>'id'=r->>'unit_id')) then raise exception 'Backup contains a product with an unknown unit'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') r where r->>'category_id' is not null
      and not exists (select 1 from public.product_categories c where c.id=(r->>'category_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'product_categories') c where c->>'id'=r->>'category_id')) then raise exception 'Backup contains a product with an unknown category'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'product_categories') r where r->>'parent_id' is not null
      and not exists (select 1 from public.product_categories c where c.id=(r->>'parent_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'product_categories') c where c->>'id'=r->>'parent_id')) then raise exception 'Backup contains a category with an unknown parent'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') r where not exists (select 1 from public.suppliers s where s.id=(r->>'supplier_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'suppliers') s where s->>'id'=r->>'supplier_id')) then raise exception 'Backup contains a purchase with an unknown supplier'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') r where r->>'branch_id' is not null
      and not exists (select 1 from public.branches b where b.id=(r->>'branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'branch_id')) then raise exception 'Backup contains a purchase with an unknown branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') r where r->>'customer_id' is not null
      and not exists (select 1 from public.customers c where c.id=(r->>'customer_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'customers') c where c->>'id'=r->>'customer_id')) then raise exception 'Backup contains a sale with an unknown customer'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') r where r->>'branch_id' is not null
      and not exists (select 1 from public.branches b where b.id=(r->>'branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'branch_id')) then raise exception 'Backup contains a sale with an unknown branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_items') r where not exists (select 1 from public.purchases p where p.id=(r->>'purchase_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') p where p->>'id'=r->>'purchase_id')) then raise exception 'Backup contains an item with an unknown purchase'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_items') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains a purchase item with an unknown product'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sale_items') r where not exists (select 1 from public.sales s where s.id=(r->>'sale_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') s where s->>'id'=r->>'sale_id')) then raise exception 'Backup contains an item with an unknown sale'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sale_items') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains a sale item with an unknown product'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'supplier_payments') r where not exists (select 1 from public.suppliers s where s.id=(r->>'supplier_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'suppliers') s where s->>'id'=r->>'supplier_id')) then raise exception 'Backup contains a supplier payment with an unknown supplier'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'supplier_payments') r where r->>'purchase_id' is not null
      and not exists (select 1 from public.purchases p where p.id=(r->>'purchase_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') p where p->>'id'=r->>'purchase_id')) then raise exception 'Backup contains a supplier payment with an unknown purchase'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payments') r where r->>'customer_id' is not null
      and not exists (select 1 from public.customers c where c.id=(r->>'customer_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'customers') c where c->>'id'=r->>'customer_id')) then raise exception 'Backup contains a payment with an unknown customer'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payment_allocations') r where not exists (select 1 from public.payments p where p.id=(r->>'payment_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p where p->>'id'=r->>'payment_id')) then raise exception 'Backup contains an allocation with an unknown payment'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payment_allocations') r where r->>'sale_id' is not null
      and not exists (select 1 from public.sales s where s.id=(r->>'sale_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') s where s->>'id'=r->>'sale_id')) then raise exception 'Backup contains an allocation with an unknown sale'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'expenses') r where r->>'category_id' is not null
      and not exists (select 1 from public.expense_categories c where c.id=(r->>'category_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'expense_categories') c where c->>'id'=r->>'category_id')) then raise exception 'Backup contains an expense with an unknown category'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_adjustments') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains an adjustment with an unknown product'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_adjustments') r where r->>'branch_id' is not null
      and not exists (select 1 from public.branches b where b.id=(r->>'branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'branch_id')) then raise exception 'Backup contains an adjustment with an unknown branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains a stock movement with an unknown product'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'branch_id' is not null
      and not exists (select 1 from public.branches b where b.id=(r->>'branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'branch_id')) then raise exception 'Backup contains a stock movement with an unknown branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'reference_type'='sale'
      and not exists (select 1 from public.sales s where s.id=(r->>'reference_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') s where s->>'id'=r->>'reference_id')) then raise exception 'Backup contains a stock movement with an unknown sale'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'reference_type'='purchase'
      and not exists (select 1 from public.purchases p where p.id=(r->>'reference_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') p where p->>'id'=r->>'reference_id')) then raise exception 'Backup contains a stock movement with an unknown purchase'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'reference_type'='adjustment'
      and not exists (select 1 from public.stock_adjustments a where a.id=(r->>'reference_id')::uuid and a.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_adjustments') a where a->>'id'=r->>'reference_id')) then raise exception 'Backup contains a stock movement with an unknown adjustment'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'reference_type'='stock_transfer'
      and not exists (select 1 from public.stock_transfers t where t.id=(r->>'reference_id')::uuid and t.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfers') t where t->>'id'=r->>'reference_id')) then raise exception 'Backup contains a stock movement with an unknown transfer'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfers') r where not exists (select 1 from public.branches b where b.id=(r->>'source_branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'source_branch_id')) then raise exception 'Backup contains a transfer with an unknown source branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfers') r where not exists (select 1 from public.branches b where b.id=(r->>'destination_branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'destination_branch_id')) then raise exception 'Backup contains a transfer with an unknown destination branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfer_items') r where not exists (select 1 from public.stock_transfers t where t.id=(r->>'transfer_id')::uuid and t.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfers') t where t->>'id'=r->>'transfer_id')) then raise exception 'Backup contains a transfer item with an unknown transfer'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfer_items') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains a transfer item with an unknown product'; end if;

  foreach table_name in array table_names loop
    if p_backup->'tables' ? table_name then
      if jsonb_typeof(p_backup->'tables'->table_name) <> 'array' then raise exception 'Backup table % is malformed', table_name; end if;
      select string_agg(format('%I = excluded.%I', a.attname, a.attname), ', ' order by a.attnum)
      into column_updates
      from pg_attribute a
      where a.attrelid = format('public.%I', table_name)::regclass
        and a.attnum > 0 and not a.attisdropped and a.attname <> 'id';
      execute format(
        'insert into public.%1$I select (r).* from jsonb_populate_recordset(null::public.%1$I, $1) r where r.organization_id = $2 on conflict (id) do update set %2$s',
        table_name, column_updates
      ) using p_backup->'tables'->table_name, p_org_id;
      get diagnostics table_count = row_count;
      restored_count := restored_count + table_count;
    end if;
  end loop;
  return jsonb_build_object('success', true, 'rows_merged', restored_count, 'mode', 'merge');
end;
$$;
revoke all on function public.restore_organization_backup(uuid,jsonb) from public, anon;
grant execute on function public.restore_organization_backup(uuid,jsonb) to authenticated;
