# Production security investigation (read-only)

**Investigation date:** 2026-11-19  
**Mode:** read-only. No SQL changes, data writes, migration execution, project switch, or credential access was performed.  
**Decision:** production security state remains unverified; do not treat the prior source-level fixes or policies as deployed.

## A. Target confirmation

- The workspace link identifies Supabase project **`wholesale-erp`**, ref **`lfajonwbfweflkymuvmx`**, environment **production**.
- This matches the production target/ref explicitly shown in the earlier project CLI output in this conversation. No project switch was made.
- `supabase/config.toml` contains local project name `myanmar-wholesale-erp`. That value is a local project identifier, not evidence of a different remote link.
- A read-only `supabase migration list --remote` was attempted with telemetry disabled. The CLI confirmed the production target, then returned `AccessTokenRequiredError` because no Supabase access token is configured. No remote migration-history query completed.

## Critical findings

### P-01 — Effective platform-admin assignments could not be reviewed

- **Severity:** Critical
- **Evidence:** Migration `0015_grant_superadmin_and_tenant_management.sql` sets `is_platform_admin=true` for every profile whose ID exists in `auth.users`. No later source migration resets those values. Production profile rows were not readable from this session.
- **Affected tables/functions:** `public.profiles.is_platform_admin`, `public.is_platform_admin()`, platform-admin RLS policies and RPCs.
- **Business impact:** If migration 0015 ran with customer accounts present, those accounts may have platform-wide authority.
- **Recommended correction:** Treat any non-allowlisted live admin as a potential incident. Compare the production admin IDs with the approved allowlist before authorizing any correction.
- **Verification:** Requires an authorized read-only database session and an explicitly supplied/approved admin allowlist. Neither was available here; see [allowlist review](platform-admin-allowlist-review.md).

### P-02 — Organization settings policy is broad in migration source

- **Severity:** High
- **Evidence:** `0013_fix_member_select_policy.sql` grants settings-row SELECT when `auth.role()='authenticated'`. `0042_tenant_security_baseline.sql` replaces organization-table read policies but does not replace this organization-settings policy. Effective production policies could not be read.
- **Affected tables/functions:** `public.organization_settings`; `public.has_org_membership(uuid)`; `public.is_platform_admin()`.
- **Business impact:** If this policy is effective, any signed-in tenant user can read other organizations' contact and configuration details.
- **Recommended correction:** Replace the blanket condition with active membership or platform-admin authorization, after inspecting every effective permissive policy.
- **Verification:** See [settings-policy review](organization-settings-policy-review.md); requires production `pg_policies`/catalog access and two-user tests.

### P-03 — Cross-tenant transaction references are not comprehensively constrained

- **Severity:** Critical
- **Evidence:** Source uses separate `organization_id` and single-column FKs for core customer, supplier, product, purchase, sale, payment, and branch relationships. `receive_purchase` joins products by ID and updates `products` by ID without an organization predicate. `confirm_sale` looks up an idempotency key without scoping it to the organization. The live constraint definitions were not inspected.
- **Affected tables/functions:** `products`, `customers`, `suppliers`, `purchases`, `purchase_items`, `sales`, `sale_items`, `payments`, `payment_allocations`, `stock_movements`, `stock_adjustments`, `branches`; `receive_purchase`, `confirm_sale`, `record_customer_payment_and_allocate`.
- **Business impact:** Mismatched references can leak data or mutate another tenant's product cost, stock, or account balances through privileged code.
- **Recommended correction:** Organization-aware composite constraints and explicit RPC validation; detailed mapping is in [cross-tenant reference review](cross-tenant-reference-review.md).
- **Verification:** Read live foreign-key definitions and run negative two-tenant RPC/FK tests in disposable staging.

### P-04 — Payment allocation limits and ownership checks are missing in source

- **Severity:** Critical
- **Evidence:** `record_customer_payment_and_allocate` does not validate that the customer belongs to `p_org_id`, that an invoice belongs to `p_customer_id`, that allocation total is at most payment amount, or that it is at most invoice outstanding.
- **Affected tables/functions:** `payments`, `payment_allocations`, `sales`; `record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text)`.
- **Business impact:** Incorrect or malicious calls can over-allocate payments and corrupt customer balances.
- **Recommended correction:** Validate tenant/customer/invoice ownership and both balance ceilings while locking affected rows; reject the entire transaction on any invalid allocation.
- **Verification:** Requires disposable PostgreSQL tests including concurrent allocation; no database was available.

### P-05 — Global cron RPC effective privileges are unknown and source revocations are incomplete

- **Severity:** Critical pending catalog verification
- **Evidence:** Several global `SECURITY DEFINER` scheduled functions have no source-level explicit `REVOKE` from client roles. PostgreSQL commonly grants function execution to `PUBLIC` by default; effective grants cannot be inferred without the live catalog. Some other routines are explicitly restricted, demonstrating different grant handling across the chain.
- **Affected tables/functions:** Subscription, notification, social-account, and marketing job tables; cron functions listed in [cron privilege review](cron-function-privilege-review.md).
- **Business impact:** If effective grants allow client invocation, unauthorized users may trigger global subscription state changes, queue notifications, or update social connection states.
- **Recommended correction:** Restrict global worker RPCs to service/scheduler roles; preserve only authenticated admin UI RPCs that perform an explicit platform-admin check.
- **Verification:** Query `has_function_privilege` for `PUBLIC`, `anon`, `authenticated`, and `service_role` in production, then exercise as non-admin/anon in staging.

### P-06 — Production migration history and effective grants are blocked

- **Severity:** Critical
- **Evidence:** The remote list command identified the correct production ref but failed before reading history with `AccessTokenRequiredError`. No production catalog or profile query was made.
- **Affected:** All migrations `0001`–`0042`; all production RLS policies, grants, constraints, functions, and triggers.
- **Business impact:** It is unknown whether production has migration 0042, whether older versions are partially applied, or whether effective grants match source.
- **Recommended correction:** An authorized operator must provide a read-only session or run reviewed catalog queries and share their sanitized results. Do not push or repair production as part of this investigation.
- **Verification:** Compare remote migration versions and catalog definitions to the local 42-migration chain; preserve query output and timestamp.

## Investigation limits and decision

No production admin IDs or associated accounts can be reported without live read access. No comparison to an authorized admin allowlist can be made because none was included or found in the repository. No production finding is confirmed as fixed. The only completed work is local source inspection and the failed read-only migration-history attempt.

**Security disposition:** Keep production release blocked until P-01 through P-06 have evidence-based resolution and staging verification. No changes were made. Stop here pending explicit approval.
