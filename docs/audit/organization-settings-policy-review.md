# Organization settings policy review

**Status:** Source-level exposure is evidenced; effective production policy state is unverified. No policy was changed.

## Finding O-01 — Blanket authenticated SELECT in migration source

- **Severity:** High
- **Affected table:** `public.organization_settings`
- **Affected policy:** `Members can view organization settings`
- **Evidence:** In `supabase/migrations/0013_fix_member_select_policy.sql` lines 15–25, the SELECT policy permits the row when `organization_id` is in the caller's memberships, the caller is a platform admin, **or** `auth.role()='authenticated'`. The final migration `0042_tenant_security_baseline.sql` replaces organization-table read policies but does not replace this settings policy. Migration `0001` also defines a separate owner/admin `FOR ALL` policy for settings.
- **Business impact:** If the policy is active as written, PostgreSQL permissive policies combine with OR semantics, so any authenticated user can read settings for other organizations, including contact details and invoice/configuration data.
- **Recommended correction:** Replace the broad settings SELECT policy with active membership or platform-admin access only, and inspect all effective SELECT policies for the table because one permissive policy can preserve the exposure.
- **Verification procedure:** In production, read-only query `pg_policies` for every policy on `public.organization_settings`, plus table grants/RLS flag. In staging, use two ordinary authenticated users from separate organizations and query all rows without frontend organization filters; each should see only its own row. Also verify an organization with no active member is invisible.

## Corrected policy proposal — not applied

After confirming policy names and roles in the target catalog, the minimal proposal matching the current helper functions is:

```sql
drop policy if exists "Members can view organization settings"
  on public.organization_settings;

create policy "Members can view organization settings"
  on public.organization_settings
  for select
  to authenticated
  using (
    public.has_org_membership(organization_id)
    or public.is_platform_admin()
  );
```

This proposal does not alter the separate admin `FOR ALL` policy or grants. Those must be reviewed in the effective catalog before deciding whether additional policy/grant changes are needed. The SQL above has not been executed.

## Production verification blocked

The linked target is production ref `lfajonwbfweflkymuvmx`. The CLI had no access token, so no catalog query was run. Consequently, this report does not claim the broad policy is currently effective or fixed in production.
