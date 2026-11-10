-- ==============================================================================
-- Migration: 0013_fix_member_select_policy.sql
-- Description: Allow users to view their own memberships in organization_members.
-- ==============================================================================

drop policy if exists "Members can view members of their organization" on public.organization_members;
create policy "Members can view members of their organization"
  on public.organization_members for select
  using (
    user_id = auth.uid()
    or public.has_org_membership(organization_id)
    or public.is_platform_admin()
  );

drop policy if exists "Members can view organization settings" on public.organization_settings;
create policy "Members can view organization settings"
  on public.organization_settings for select
  using (
    organization_id in (
      select organization_id from public.organization_members
      where user_id = auth.uid() and is_active = true
    )
    or public.is_platform_admin()
    or auth.role() = 'authenticated'
  );

-- Reload schema cache
notify pgrst, 'reload schema';

