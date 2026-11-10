-- ==============================================================================
-- Migration: 0007_expenses_and_finance.sql
-- Description: Operational expenses, expense categories, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant expense tables if they pre-exist
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'expense_categories'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'expense_categories' and column_name = 'organization_id'
  ) then
    drop table public.expense_categories cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'expenses'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'expenses' and column_name = 'organization_id'
  ) then
    drop table public.expenses cascade;
  end if;
end $$;

-- 1. Expense Categories
create table if not exists public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 100),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, name)
);

create index if not exists idx_exp_cat_org on public.expense_categories (organization_id);

-- 2. Expenses
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  category text not null default 'General',
  category_id uuid references public.expense_categories(id) on delete set null,
  expense_date date not null default current_date,
  amount numeric(14, 2) not null check (amount > 0),
  payment_method text not null default 'cash' check (payment_method in ('cash', 'bank_transfer', 'mobile_money', 'kbz_pay', 'wave_pay', 'other')),
  title text not null check (length(btrim(title)) between 1 and 200),
  notes text,
  receipt_url text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Trigger to auto-sync category text from category_id if provided
create or replace function public.sync_expense_category_name()
returns trigger
language plpgsql
as $$
begin
  if new.category_id is not null and (new.category is null or new.category = 'General') then
    select name into new.category from public.expense_categories where id = new.category_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_expense_category_name on public.expenses;
create trigger trg_sync_expense_category_name
  before insert or update on public.expenses
  for each row execute function public.sync_expense_category_name();

create index if not exists idx_expenses_org_date on public.expenses (organization_id, expense_date desc);

-- 3. Enable RLS
alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;

create policy "Members can view expense categories"
  on public.expense_categories for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage expense categories"
  on public.expense_categories for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view expenses"
  on public.expenses for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage expenses"
  on public.expenses for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

