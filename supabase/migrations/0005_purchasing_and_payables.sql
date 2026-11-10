-- ==============================================================================
-- Migration: 0005_purchasing_and_payables.sql
-- Description: Purchases, purchase items, supplier payments, receiving RPC, and RLS.
-- ==============================================================================

-- 1. Purchases
create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  purchase_number text not null,
  purchase_date date not null default current_date,
  status text not null default 'draft' check (status in ('draft', 'ordered', 'received', 'voided')),
  subtotal numeric(14, 2) not null default 0.00 check (subtotal >= 0),
  tax_amount numeric(14, 2) not null default 0.00 check (tax_amount >= 0),
  discount_amount numeric(14, 2) not null default 0.00 check (discount_amount >= 0),
  total_amount numeric(14, 2) not null default 0.00 check (total_amount >= 0),
  paid_amount numeric(14, 2) not null default 0.00 check (paid_amount >= 0),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, purchase_number)
);

create index if not exists idx_purchases_org_supp on public.purchases (organization_id, supplier_id);
create index if not exists idx_purchases_org_date on public.purchases (organization_id, purchase_date desc);

-- 2. Purchase Items
create table if not exists public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  purchase_id uuid not null references public.purchases(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(12, 2) not null check (quantity > 0),
  unit_cost numeric(14, 2) not null check (unit_cost >= 0),
  total_cost numeric(14, 2) not null check (total_cost >= 0),
  received_quantity numeric(12, 2) not null default 0.00 check (received_quantity >= 0),
  created_at timestamptz not null default now()
);

create index if not exists idx_purch_items_purchase on public.purchase_items (purchase_id);

-- 3. Supplier Payments
create table if not exists public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  purchase_id uuid references public.purchases(id) on delete set null,
  payment_number text not null,
  payment_date date not null default current_date,
  amount numeric(14, 2) not null check (amount > 0),
  payment_method text not null check (payment_method in ('cash', 'bank_transfer', 'mobile_money', 'kbz_pay', 'wave_pay', 'other')),
  reference_number text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, payment_number)
);

create index if not exists idx_supp_payments_org_supp on public.supplier_payments (organization_id, supplier_id);

-- 4. Atomic RPC: Receive Purchase Order
create or replace function public.receive_purchase(
  p_org_id uuid,
  p_purchase_id uuid,
  p_amount_paid numeric default 0.00,
  p_payment_method text default 'cash'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_purchase public.purchases%rowtype;
  v_item record;
  v_current_stock numeric(12, 2);
  v_new_avg_cost numeric(14, 4);
  v_payment_number text;
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  select * into v_purchase
  from public.purchases
  where id = p_purchase_id and organization_id = p_org_id
  for update;

  if not found then
    raise exception 'Purchase order not found';
  end if;

  if v_purchase.status = 'received' then
    raise exception 'Purchase is already marked received';
  end if;

  if v_purchase.status = 'voided' then
    raise exception 'Cannot receive a voided purchase order';
  end if;

  -- Process line items
  for v_item in
    select pi.*, p.average_cost as prod_avg_cost
    from public.purchase_items pi
    join public.products p on p.id = pi.product_id
    where pi.purchase_id = p_purchase_id
  loop
    -- Calculate current stock from ledger
    select coalesce(sum(quantity), 0.00) into v_current_stock
    from public.stock_movements
    where organization_id = p_org_id and product_id = v_item.product_id;

    -- Calculate weighted average cost
    if (v_current_stock + v_item.quantity) > 0 then
      if v_current_stock <= 0 then
        v_new_avg_cost := v_item.unit_cost;
      else
        v_new_avg_cost := ((v_current_stock * v_item.prod_avg_cost) + (v_item.quantity * v_item.unit_cost)) / (v_current_stock + v_item.quantity);
      end if;
    else
      v_new_avg_cost := v_item.unit_cost;
    end if;

    -- Update product average cost and purchase price
    update public.products
    set average_cost = v_new_avg_cost,
        purchase_price = v_item.unit_cost,
        updated_at = now()
    where id = v_item.product_id;

    -- Record stock movement ledger entry
    insert into public.stock_movements (
      organization_id, product_id, movement_type, quantity,
      unit_cost, reference_type, reference_id, created_by
    )
    values (
      p_org_id, v_item.product_id, 'purchase_in', v_item.quantity,
      v_item.unit_cost, 'purchase', p_purchase_id, v_user_id
    );

    -- Update received quantity on purchase item
    update public.purchase_items
    set received_quantity = quantity
    where id = v_item.id;
  end loop;

  -- Record payment if paid upfront
  if p_amount_paid > 0 then
    v_payment_number := public.next_document_number(p_org_id, 'supplier_payment');
    insert into public.supplier_payments (
      organization_id, supplier_id, purchase_id, payment_number,
      payment_date, amount, payment_method, created_by
    )
    values (
      p_org_id, v_purchase.supplier_id, p_purchase_id, v_payment_number,
      current_date, p_amount_paid, p_payment_method, v_user_id
    );
  end if;

  -- Mark purchase received
  update public.purchases
  set status = 'received',
      paid_amount = coalesce(paid_amount, 0) + coalesce(p_amount_paid, 0),
      updated_at = now()
  where id = p_purchase_id;

  return jsonb_build_object(
    'success', true,
    'purchase_id', p_purchase_id,
    'status', 'received'
  );
end;
$$;

-- 5. Enable RLS
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;
alter table public.supplier_payments enable row level security;

create policy "Members can view purchases"
  on public.purchases for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Managers+ can manage purchases"
  on public.purchases for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view purchase items"
  on public.purchase_items for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Managers+ can manage purchase items"
  on public.purchase_items for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view supplier payments"
  on public.supplier_payments for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Managers+ can record supplier payments"
  on public.supplier_payments for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

