-- ==============================================================================
-- Migration: 0011_add_slug_to_organizations.sql
-- Description: Ensure organizations table has slug, currency, timezone, is_active.
-- ==============================================================================

alter table public.organizations 
  add column if not exists slug text,
  add column if not exists currency text not null default 'MMK',
  add column if not exists timezone text not null default 'Asia/Yangon',
  add column if not exists tax_id text,
  add column if not exists is_active boolean not null default true;

-- Ensure unique constraint on slug if not exists
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'organizations_slug_key'
  ) then
    alter table public.organizations add constraint organizations_slug_key unique (slug);
  end if;
end $$;

-- Enable RLS and insert policy for authenticated users
alter table public.organizations enable row level security;

drop policy if exists "Authenticated users can create organization" on public.organizations;
create policy "Authenticated users can create organization"
  on public.organizations for insert
  with check (auth.role() = 'authenticated');

drop policy if exists "Members can view own organization" on public.organizations;
create policy "Members can view own organization"
  on public.organizations for select
  using (
    id in (
      select organization_id from public.organization_members
      where user_id = auth.uid() and is_active = true
    ) or public.is_platform_admin()
  );

drop policy if exists "Admins and owners can update organization" on public.organizations;
create policy "Admins and owners can update organization"
  on public.organizations for update
  using (public.is_org_admin_or_owner(id) or public.is_platform_admin());

-- Force PostgREST schema cache reload
notify pgrst, 'reload schema';
