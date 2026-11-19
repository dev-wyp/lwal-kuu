# Security containment plan (proposal only)

**Status:** Investigation and proposed actions only. No containment change was executed. The linked project is production, and the Supabase CLI has no access token; effective live state remains unknown.

## Immediate read-only checks for an authorized operator

| Priority | Severity | Evidence to collect | Tables/functions | Business impact | Verification method |
| --- | --- | --- | --- | --- | --- |
| 1 | Critical | Current `is_platform_admin=true` IDs/accounts, profile creation times, approved allowlist, and admin activity/audit history | `profiles`, `auth.users`, `audit_logs`, `is_platform_admin()` | Unexpected platform admins can access every tenant and platform operations | Read-only admin ID query and allowlist diff; inspect available admin audit events |
| 2 | High | Every current settings SELECT policy, table grant, RLS flag | `organization_settings`, `pg_policies`, ACLs | A broad permissive policy can expose all tenant settings | Catalog query plus two-user staging isolation test |
| 3 | Critical | Effective EXECUTE ACLs and scheduled job owner/role | All functions in `cron-function-privilege-review.md`; `cron.job` | Unauthorized global jobs can mutate subscription/notification/social state | `has_function_privilege`/ACL catalog review; anon and ordinary-user staging calls |
| 4 | Critical | Production migration versions and all FK definitions | migrations `0001`–`0042`, tenant transaction tables | Source may differ from effective database contract | Read-only `supabase migration list --remote` plus catalog/schema comparison |
| 5 | Critical | Existing cross-tenant reference mismatch counts before considering constraints | Purchase/sales/payment/inventory/branch relationships in `cross-tenant-reference-review.md` | Existing bad links can cause cross-tenant mutation or prevent a safe constraint migration | Read-only aggregate mismatch queries; export counts only, do not repair in place |

## Proposed remediation order after approval

1. **Admin exposure:** after allowlist and incident review, draft a narrowly scoped, reviewed admin-correction migration or controlled operator process. Never blanket-update profiles.
2. **Settings isolation:** inspect the complete policy set; prepare a migration that replaces only confirmed broad policies and keeps valid admin access.
3. **Cron privileges:** prepare revokes/grants matching actual scheduled-job and Edge Function identities. Retain platform-admin UI only for explicitly guarded manual functions.
4. **Tenant references:** build mismatch reports first; design additive composite constraints and RPC checks against the real production schema. Preserve existing valid business transactions and handle invalid legacy rows under a separately approved data plan.
5. **Payment and workflow integrity:** create transaction-safe server-side checks and reversal design; test against disposable staging fixtures, including concurrency and rollback.
6. **Migration/staging release:** establish a verified backup, restore it into staging, compare migration history, apply reviewed migrations to staging, run RLS/transaction/reconciliation suites, and complete owner UAT before any production decision.

## Change-control requirements

- Do not apply any proposal SQL until an explicit implementation/deployment approval is given.
- Do not test by writing fixtures to production.
- Use a disposable Supabase database or isolated staging project for tests; never reset production.
- Store credentials only in the authorized local secret manager/CLI environment. Do not paste tokens or service-role keys into reports or chat.
- Record pre/post migration versions, backup verification, catalog diffs, and test results in the release record.

## Current blockers

- **Production read access:** blocked because no Supabase access token is configured. The target ref itself was confirmed and matches the previously provided production ref.
- **Admin allowlist:** blocked because no explicit authorized user-ID allowlist was provided or found in repository documentation.
- **Effective grants/policies/data:** blocked because no production catalog or profile query was possible.
- **Runtime database tests:** blocked because local Docker/PostgreSQL is unavailable and no isolated staging database credentials were supplied.

## Stop condition

This document is a plan, not a fix. No source code, SQL, production data, policies, grants, or migrations were changed. Stop here until explicit approval and the required read-only evidence are available.
