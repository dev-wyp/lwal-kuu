-- ==============================================================================
-- Migration: 0006_sales_and_receivables.sql
-- Description: Sales, sale items, payments, allocations, confirm sale RPC, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant sales and payment tables if they pre-exist
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'sales'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'sales' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'sale_items'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'sale_items' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'payments'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'payments' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'payment_allocations'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'payment_allocations' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;
end $$;

-- 1. Sales
create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete restrict,
  invoice_number text not null,
  invoice_no text,
  sale_date date not null default current_date,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'voided', 'reversed')),
  subtotal numeric(14, 2) not null default 0.00 check (subtotal >= 0),
  discount_amount numeric(14, 2) not null default 0.00 check (discount_amount >= 0),
  tax_amount numeric(14, 2) not null default 0.00 check (tax_amount >= 0),
  total numeric(14, 2) not null default 0.00 check (total >= 0),
  total_amount numeric(14, 2) not null default 0.00 check (total_amount >= 0),
  total_cost numeric(14, 2) not null default 0.00 check (total_cost >= 0),
  paid_amount numeric(14, 2) not null default 0.00 check (paid_amount >= 0),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'partial', 'paid')),
  due_date date,
  notes text,
  idempotency_key text unique,
  voided_at timestamptz,
  void_reason text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, invoice_number)
);

create or replace function public.sync_sale_fields()
returns trigger
language plpgsql
as $$
begin
  if new.invoice_no is null or new.invoice_no = '' then
    new.invoice_no := new.invoice_number;
  elsif new.invoice_number is null or new.invoice_number = '' then
    new.invoice_number := new.invoice_no;
  end if;

  if new.total = 0 and new.total_amount > 0 then
    new.total := new.total_amount;
  elsif new.total_amount = 0 and new.total > 0 then
    new.total_amount := new.total;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_sale_fields on public.sales;
create trigger trg_sync_sale_fields
  before insert or update on public.sales
  for each row execute function public.sync_sale_fields();

create index if not exists idx_sales_org_customer on public.sales (organization_id, customer_id);
create index if not exists idx_sales_org_date on public.sales (organization_id, sale_date desc);
create index if not exists idx_sales_status on public.sales (organization_id, status);

-- 2. Sale Items
create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(12, 2) not null check (quantity > 0),
  unit_price numeric(14, 2) not null check (unit_price >= 0),
  unit_cost numeric(14, 4) not null default 0.0000,
  discount_amount numeric(14, 2) not null default 0.00 check (discount_amount >= 0),
  total_amount numeric(14, 2) not null check (total_amount >= 0),
  created_at timestamptz not null default now()
);

create index if not exists idx_sale_items_sale on public.sale_items (sale_id);

-- 3. Customer & Unified Payments
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete restrict,
  payment_type text not null default 'customer_payment' check (payment_type in ('customer_payment', 'supplier_payment', 'other')),
  payment_number text not null,
  payment_date date not null default current_date,
  amount numeric(14, 2) not null check (amount > 0),
  allocated_amount numeric(14, 2) not null default 0.00 check (allocated_amount >= 0),
  payment_method text not null default 'cash' check (payment_method in ('cash', 'bank_transfer', 'mobile_money', 'kbz_pay', 'wave_pay', 'other')),
  method text,
  reference_number text,
  notes text,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  idempotency_key text unique,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, payment_number)
);

create or replace function public.sync_payment_fields()
returns trigger
language plpgsql
as $$
begin
  if new.method is null or new.method = '' then
    new.method := new.payment_method;
  elsif new.payment_method is null or new.payment_method = '' then
    new.payment_method := new.method;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_payment_fields on public.payments;
create trigger trg_sync_payment_fields
  before insert or update on public.payments
  for each row execute function public.sync_payment_fields();

create index if not exists idx_payments_org_customer on public.payments (organization_id, customer_id);

-- 4. Payment Allocations
create table if not exists public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  payment_id uuid not null references public.payments(id) on delete cascade,
  sale_id uuid references public.sales(id) on delete cascade,
  document_type text not null default 'sale',
  document_id uuid,
  amount numeric(14, 2) not null default 0.00,
  allocated_amount numeric(14, 2) not null default 0.00 check (allocated_amount >= 0),
  created_at timestamptz not null default now()
);

create or replace function public.sync_payment_alloc_fields()
returns trigger
language plpgsql
as $$
begin
  if new.document_id is null and new.sale_id is not null then
    new.document_id := new.sale_id;
  elsif new.sale_id is null and new.document_id is not null and new.document_type = 'sale' then
    new.sale_id := new.document_id;
  end if;

  if new.amount = 0 and new.allocated_amount > 0 then
    new.amount := new.allocated_amount;
  elsif new.allocated_amount = 0 and new.amount > 0 then
    new.allocated_amount := new.amount;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_payment_alloc_fields on public.payment_allocations;
create trigger trg_sync_payment_alloc_fields
  before insert or update on public.payment_allocations
  for each row execute function public.sync_payment_alloc_fields();

create index if not exists idx_payment_alloc_sale on public.payment_allocations (sale_id);
create index if not exists idx_payment_alloc_doc on public.payment_allocations (document_type, document_id);

-- 5. Atomic RPC: Confirm Sale
create or replace function public.confirm_sale(
  p_org_id uuid,
  p_sale_id uuid,
  p_payment_method text default 'cash',
  p_amount_paid numeric default 0.00,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_sale public.sales%rowtype;
  v_item record;
  v_current_stock numeric(12, 2);
  v_total_cost numeric(14, 2) := 0.00;
  v_paid numeric(14, 2) := coalesce(p_amount_paid, 0.00);
  v_pay_status text;
  v_payment_id uuid;
  v_payment_num text;
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  -- Check idempotency
  if p_idempotency_key is not null then
    select * into v_sale from public.sales where idempotency_key = p_idempotency_key;
    if found and v_sale.status = 'confirmed' then
      return jsonb_build_object('success', true, 'sale_id', v_sale.id, 'invoice_number', v_sale.invoice_number);
    end if;
  end if;

  -- Lock sale row
  select * into v_sale
  from public.sales
  where id = p_sale_id and organization_id = p_org_id
  for update;

  if not found then
    raise exception 'Sale not found';
  end if;

  if v_sale.status = 'confirmed' then
    raise exception 'Sale is already confirmed';
  end if;

  if v_sale.status in ('voided', 'reversed') then
    raise exception 'Cannot confirm a voided or reversed sale';
  end if;

  -- Stock check & Ledger movements
  for v_item in
    select si.*, p.sku, p.name as prod_name, p.average_cost as current_avg_cost
    from public.sale_items si
    join public.products p on p.id = si.product_id
    where si.sale_id = p_sale_id
  loop
    select coalesce(sum(quantity), 0.00) into v_current_stock
    from public.stock_movements
    where organization_id = p_org_id and product_id = v_item.product_id;

    if v_current_stock < v_item.quantity then
      raise exception 'Insufficient stock for product % (Available: %, Requested: %)',
        v_item.prod_name, v_current_stock, v_item.quantity;
    end if;

    -- Freeze unit cost at time of sale
    update public.sale_items
    set unit_cost = v_item.current_avg_cost
    where id = v_item.id;

    v_total_cost := v_total_cost + (v_item.quantity * v_item.current_avg_cost);

    -- Insert sales_out movement
    insert into public.stock_movements (
      organization_id, product_id, movement_type, quantity,
      unit_cost, reference_type, reference_id, created_by
    )
    values (
      p_org_id, v_item.product_id, 'sales_out', -v_item.quantity,
      v_item.current_avg_cost, 'sale', p_sale_id, v_user_id
    );
  end loop;

  -- Payment status calculation
  if v_paid >= v_sale.total_amount then
    v_pay_status := 'paid';
  elsif v_paid > 0 then
    v_pay_status := 'partial';
  else
    v_pay_status := 'unpaid';
  end if;

  -- Update sale
  update public.sales
  set status = 'confirmed',
      total_cost = v_total_cost,
      paid_amount = v_paid,
      payment_status = v_pay_status,
      idempotency_key = p_idempotency_key,
      updated_at = now()
  where id = p_sale_id;

  -- Record upfront payment if any
  if v_paid > 0 and v_sale.customer_id is not null then
    v_payment_num := public.next_document_number(p_org_id, 'customer_payment');
    insert into public.payments (
      organization_id, customer_id, payment_number, payment_date,
      amount, allocated_amount, payment_method, status, created_by
    )
    values (
      p_org_id, v_sale.customer_id, v_payment_num, current_date,
      v_paid, v_paid, p_payment_method, 'posted', v_user_id
    )
    returning id into v_payment_id;

    insert into public.payment_allocations (
      organization_id, payment_id, sale_id, allocated_amount
    )
    values (
      p_org_id, v_payment_id, p_sale_id, v_paid
    );
  end if;

  -- Log audit
  insert into public.audit_logs (
    organization_id, user_id, action, entity_type, entity_id, payload
  )
  values (
    p_org_id, v_user_id, 'sale.confirm', 'sale', p_sale_id,
    jsonb_build_object('invoice_number', v_sale.invoice_number, 'total', v_sale.total_amount, 'paid', v_paid)
  );

  return jsonb_build_object(
    'success', true,
    'sale_id', p_sale_id,
    'invoice_number', v_sale.invoice_number,
    'payment_status', v_pay_status
  );
end;
$$;

-- 6. Atomic RPC: Void / Reverse Sale
create or replace function public.void_or_reverse_sale(
  p_org_id uuid,
  p_sale_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_sale public.sales%rowtype;
  v_item record;
begin
  if not public.is_org_admin_or_owner(p_org_id) then
    raise exception 'Only Admins and Owners can void or reverse sales';
  end if;

  select * into v_sale
  from public.sales
  where id = p_sale_id and organization_id = p_org_id
  for update;

  if not found then
    raise exception 'Sale not found';
  end if;

  if v_sale.status in ('voided', 'reversed') then
    raise exception 'Sale is already voided or reversed';
  end if;

  -- If draft, simply mark voided
  if v_sale.status = 'draft' then
    update public.sales
    set status = 'voided', voided_at = now(), void_reason = p_reason, updated_at = now()
    where id = p_sale_id;

    return jsonb_build_object('success', true, 'status', 'voided');
  end if;

  -- If confirmed, perform compensatory stock reversal
  for v_item in select * from public.sale_items where sale_id = p_sale_id loop
    insert into public.stock_movements (
      organization_id, product_id, movement_type, quantity,
      unit_cost, reference_type, reference_id, notes, created_by
    )
    values (
      p_org_id, v_item.product_id, 'sale_reversal', v_item.quantity,
      v_item.unit_cost, 'sale', p_sale_id, 'Reversal: ' || coalesce(p_reason, 'No reason'), v_user_id
    );
  end loop;

  -- Mark status reversed
  update public.sales
  set status = 'reversed',
      voided_at = now(),
      void_reason = p_reason,
      updated_at = now()
  where id = p_sale_id;

  -- Log audit
  insert into public.audit_logs (
    organization_id, user_id, action, entity_type, entity_id, payload
  )
  values (
    p_org_id, v_user_id, 'sale.reverse', 'sale', p_sale_id,
    jsonb_build_object('invoice_number', v_sale.invoice_number, 'reason', p_reason)
  );

  return jsonb_build_object('success', true, 'status', 'reversed');
end;
$$;

-- 7. Atomic RPC: Record Customer Payment and Allocate
create or replace function public.record_customer_payment_and_allocate(
  p_org_id uuid,
  p_customer_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_allocations jsonb,
  p_reference_number text default null,
  p_notes text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_payment_num text;
  v_payment_id uuid;
  v_total_allocated numeric(14, 2) := 0.00;
  v_alloc jsonb;
  v_sale_id uuid;
  v_alloc_amt numeric(14, 2);
  v_sale public.sales%rowtype;
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  if p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;

  v_payment_num := public.next_document_number(p_org_id, 'customer_payment');

  insert into public.payments (
    organization_id, customer_id, payment_number, payment_date,
    amount, allocated_amount, payment_method, reference_number,
    notes, status, idempotency_key, created_by
  )
  values (
    p_org_id, p_customer_id, v_payment_num, current_date,
    p_amount, 0.00, p_payment_method, p_reference_number,
    p_notes, 'posted', p_idempotency_key, v_user_id
  )
  returning id into v_payment_id;

  -- Process allocations
  if p_allocations is not null and jsonb_array_length(p_allocations) > 0 then
    for v_alloc in select * from jsonb_array_elements(p_allocations) loop
      v_sale_id := (v_alloc->>'sale_id')::uuid;
      v_alloc_amt := (v_alloc->>'amount')::numeric;

      if v_alloc_amt > 0 then
        select * into v_sale from public.sales where id = v_sale_id and organization_id = p_org_id for update;

        if found and v_sale.status = 'confirmed' then
          insert into public.payment_allocations (organization_id, payment_id, sale_id, allocated_amount)
          values (p_org_id, v_payment_id, v_sale_id, v_alloc_amt);

          v_total_allocated := v_total_allocated + v_alloc_amt;

          update public.sales
          set paid_amount = paid_amount + v_alloc_amt,
              payment_status = case
                when (paid_amount + v_alloc_amt) >= total_amount then 'paid'
                else 'partial'
              end,
              updated_at = now()
          where id = v_sale_id;
        end if;
      end if;
    end loop;
  end if;

  -- Update payment allocated amount
  update public.payments
  set allocated_amount = v_total_allocated
  where id = v_payment_id;

  return jsonb_build_object(
    'success', true,
    'payment_id', v_payment_id,
    'payment_number', v_payment_num,
    'allocated_amount', v_total_allocated
  );
end;
$$;

-- 8. Enable RLS
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;

create policy "Members can view sales"
  on public.sales for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage sales"
  on public.sales for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view sale items"
  on public.sale_items for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage sale items"
  on public.sale_items for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view payments"
  on public.payments for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can create payments"
  on public.payments for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view payment allocations"
  on public.payment_allocations for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can create allocations"
  on public.payment_allocations for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

