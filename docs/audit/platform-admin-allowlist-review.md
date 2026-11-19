# Platform-admin allowlist review

**Status:** Blocked pending an authorized read-only database result and an explicit approved allowlist. This report contains no production user IDs because the database could not be queried.

## Finding A-01 — Migration promotes all users present at migration time

- **Severity:** Critical potential incident
- **Evidence:** `supabase/migrations/0015_grant_superadmin_and_tenant_management.sql` lines 6–9 updates every `public.profiles` row whose ID exists in `auth.users` to `is_platform_admin=true`. The migration comment calls this a development/launch bootstrap, but the SQL predicate is not limited to one account. No later migration in `0001`–`0042` demotes the resulting profiles.
- **Affected tables/functions:** `public.profiles`; `public.is_platform_admin()`; admin policies and platform RPCs.
- **Business impact:** Every account that existed when migration 0015 ran may have received platform-wide access, including access to tenant data and administrative functions.
- **Recommended correction:** First establish which IDs are currently platform admins and compare to a separately approved allowlist. Unexpected rows should be treated as a possible security incident and handled only through an approved incident response. Do not infer that the source-level profile grant added in migration 0042 neutralizes historical data values.
- **Verification procedure:** In an authorized, read-only production session, select `profiles.id`, associated `auth.users.email`/created timestamp, and `is_platform_admin` for admin rows; compare IDs against the signed-off allowlist; preserve audit evidence. Then test representative approved and non-approved accounts against platform routes/RPCs in staging.

## Allowlist comparison

| Item | Result |
| --- | --- |
| Explicit authorized admin allowlist supplied in this request | No |
| Allowlist found in repository source/docs | No authoritative ID allowlist found; docs only explain that a profile flag grants platform privileges |
| Production admin IDs/accounts queried | No — remote database access was unavailable |
| Unexpected live admin account identified | Cannot determine |
| Promotion/demotion performed | No |

**Severity:** Critical unresolved verification gap.  
**Affected:** `public.profiles.is_platform_admin`.  
**Business impact:** The most powerful application role cannot be bounded without a trusted expected set.  
**Recommended correction:** Have the system owner provide the approved admin IDs through the authorized incident/release process, then compare using a read-only query.  
**Verification:** Record the allowlist source, query timestamp, live result count, and exact match/mismatch result; do not put credentials in the report.

## Current access limitation

The linked target is production project `wholesale-erp` (`lfajonwbfweflkymuvmx`), which matches the previously approved production ref. The read-only Supabase migration-list command failed because no Supabase access token was configured. This audit did not attempt a login, retrieve credentials, or query user records by another means.
