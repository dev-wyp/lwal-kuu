# Phase B Test Status and Coverage Matrices

**Date:** 2026-11-20  
**Execution status:** All database test rows below are **NOT RUN**. This document maps checked-in assertions to required acceptance cases; source presence is not a passing test result.

## SQL/test execution report

| Command / suite | Target | Result | Detail |
| --- | --- | --- | --- |
| `npm run lint` | Local source | PASS | Completed on 2026-11-20; ESLint returned exit code 0. |
| `npm run build` | Local source | PASS | Completed on 2026-11-20; TypeScript and Vite build succeeded. |
| `npm run test:unit` | Local source | PASS | Completed on 2026-11-20; business logic, marketing logic, and plan-presentation suites passed. |
| `git diff --check` | Workspace changes | PASS | Completed after diagnostic and documentation updates; no whitespace errors. |
| `npx supabase start` | Local disposable Supabase | BLOCKED / NOT RUN | Docker daemon unavailable in this environment. |
| `SUPABASE_TELEMETRY_DISABLED=1 supabase db query --read-only --remote=lfajonwbfweflkymuvmx --output-format json "select current_database() as database_name, current_setting('server_version') as postgres_version, current_user as connected_role;"` | Explicit CLI target resolved to `wholesale-erp` production (`lfajonwbfweflkymuvmx`) | BLOCKED before query execution | CLI returned `DbQueryLoginRequiredError: Access token not provided`. No database connection or SQL query was executed. Do not paste an access token into chat; authenticate the local CLI in the operator's environment if database review is to continue. |
| `npx supabase db reset --local` | Local disposable Supabase only | NOT RUN | Requires local Supabase; no reset was run. |
| `psql ... -f supabase/tests/p0_transaction_integrity.test.sql` | Local disposable PostgreSQL | NOT RUN | No disposable database available. Earlier scratch PostgreSQL startup failed at shared memory allocation (`shmget`, operation not permitted). |
| `psql ... -f supabase/tests/tenant_security.test.sql` | Local disposable PostgreSQL | NOT RUN | Same environment limitation. |
| `psql ... -f supabase/tests/plan_feature_matrix.test.sql` | Local disposable PostgreSQL | NOT RUN | Same environment limitation. |
| Two-session supplier concurrency procedure in `PHASE_B_STAGING_VERIFICATION.md` | Disposable database only | NOT RUN | No approved disposable/staging database supplied. |
| `npm run test:e2e` | Isolated test backend only | NOT RUN | No isolated Supabase backend. The linked project was identified as production in prior local checks and was not used. |
| Production SQL, migrations, or data operations | Production | NOT EXECUTED | Explicitly forbidden for this task. |

No migration versions were applied as part of this task. No SQL PASS result is claimed.

## P0 transaction/security coverage matrix

| Domain | Acceptance cases represented in checked-in source/tests | Test artifact | Execution result | Remaining gap |
| --- | --- | --- | --- | --- |
| Sales | Same-org branch/product/customer; server totals; invalid discount/payment; locked stock; same-key equivalent retry; changed-payload rejection; no duplicate stock/payment/audit | `0043`; `p0_transaction_integrity.test.sql` | NOT RUN | Concurrent checkout and broad two-tenant direct API coverage need isolated DB. |
| Customer payments | Same customer/confirmed invoices; allocation cap/outstanding; advance; `0047` request fingerprint; retry and changed allocations/notes; atomic effects | `0043`, `0047`; `p0_transaction_integrity.test.sql` | NOT RUN | Concurrent same-key race and changed reference/amount/method cases need execution/coverage review. |
| Purchasing/receiving | Same-org supplier/product/branch; quantity/payable; duplicate receive rejection; movements/cost; rollback | `0043`; `p0_transaction_integrity.test.sql` | NOT RUN | Partial GRN history is not implemented; weighted-cost and rollback behavior need DB verification. |
| Supplier payments | Full/partial; multi-purchase allocations; advances; over-allocation; idempotent retries; cross-tenant rejection; audit/rollback | `0044`; `p0_transaction_integrity.test.sql` | NOT RUN / migration blocked | Existing allocation schema unknown; concurrency requires two sessions; later advance allocation and reversal are not implemented. |
| Tenant security | Two organizations; membership/role checks; direct tenant access; settings policy; composite FK enforcement | `0043`, `0045`; `tenant_security.test.sql` | NOT RUN | Role-by-role reads/writes, view/RPC bypass and effective deployed grants need database execution. |
| Cron RPC privileges | Client revocations and service-role grants in migration source | `0043`; catalog diagnostic/review | NOT RUN | Effective ACLs and actual scheduler job owner require catalog results in isolated target. |
| Restore safety | Existing JSON restore implementation can merge business rows | `0039`; no complete regression suite | NOT VERIFIED | Posted-ledger immutability and audited compensation remain unresolved. |

## Pricing entitlement and resource-limit matrix

`PLAN_FEATURE_GAP_MATRIX.md` contains every one of the 42 booleans and five limits for Starter, Business, and Pro. The checked-in SQL suite targets stored assignments and runtime enforcement. This summary does not duplicate or override those per-plan assignments.

| Coverage group | Intended cases | Test artifact | Execution result | Known outstanding coverage |
| --- | --- | --- | --- | --- |
| Standard plan feature assignments | All 42 boolean assignments for Starter, Business, Pro | `supabase/tests/plan_feature_matrix.test.sql` | NOT RUN | Compare actual deployed plan rows only after authorized diagnostic access. |
| Resource limits | Five limits per plan; normalized rows and legacy fallback | `supabase/tests/plan_feature_matrix.test.sql`; migration `0046` | NOT RUN | Concurrent two-session limit race. |
| Runtime allow/deny | Starter/Business/Pro for each feature via runtime entitlement check | `supabase/tests/plan_feature_matrix.test.sql` | NOT RUN | Direct table/RPC coverage for every gated feature is not exhaustive. |
| Custom plans | Explicit assignments do not inherit standard plan features | `supabase/tests/plan_feature_matrix.test.sql` | NOT RUN | Custom-plan production rows unverified. |
| Subscription lifecycle | Expiry denial and subscription state cases | `supabase/tests/plan_feature_matrix.test.sql` | NOT RUN | Trial, grace, cancellation, upgrade/downgrade, renewal, override expiry and restoration need broader cases. |
| Quota enforcement | Existing usage/limit and Starter active-user quota rejection | `supabase/tests/plan_feature_matrix.test.sql` | NOT RUN | Concurrent creation at limit and downgrade with existing over-limit rows. |
| Tenant isolation under entitlement | Entitlement never authorizes another tenant's data | `tenant_security.test.sql`; `plan_feature_matrix.test.sql` | NOT RUN | Full role/tenant matrix across direct reads, writes, views and RPCs. |
| Pricing UI presentation | Cumulative tiers, custom-plan feature display, limit fallback, savings | `tests/unit/plan-presentation.test.mjs` | Source test previously reported PASS; not rerun in this task | Signed-in subscription, feature denial UX and E2E/API bypass cases. |

The 42-feature/5-limit SQL suite is present in source, but its presence does not establish correct deployed values, access behavior, or a passing runtime test. Do not change prices or assignments as part of this verification.

## Reversal deliverable status

No supplier-payment reversal design or implementation was started. The task's final instruction says not to start later phases, while reversal is separately assigned to a later phase; honoring the stop gate takes precedence here. The existing runbook records only the need for compensating transactions, immutable source references, amount/advance semantics, idempotency, permissions, and audit history. A reviewed reversal contract remains an explicit future blocker.

