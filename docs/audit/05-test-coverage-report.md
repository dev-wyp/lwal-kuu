# Test coverage and execution report

**Audit date:** 2026-11-18  
**Node:** `v23.11.0` / npm `11.7.0`

## Requested commands

| Command | Result | Evidence / notes |
| --- | --- | --- |
| `npm ci` | Passed | Installed 275 packages. npm reported an engine warning: `eslint-visitor-keys@5.0.1` requests Node `^20.19.0 || ^22.13.0 || >=24`; runtime was Node 23.11.0. It also reported the installed ESLint 9.39.5 release as deprecated/unsupported. |
| `npx tsc --noEmit` | Passed | Exit code 0. |
| `npm run lint` | Passed | Exit code 0. |
| `npm run build` | Passed | TypeScript build and Vite production build completed. Vite noted the existing `vendor-utils` chunk is empty. |
| `npm run test:unit` | Passed | Business logic and marketing logic tests passed. These are JavaScript unit tests, not PostgreSQL transaction tests. |
| `npm run test:e2e` | Passed after local bind permission | Initial sandbox attempt failed to bind the Vite server (`EPERM`); the same requested suite was then run with localhost binding permission and completed 5/5 Chromium tests. Coverage is public pricing/navigation, authentication form validation, marketing route authentication, and responsive page widths. |
| `supabase test db` / tenant SQL tests | Not run | Docker daemon unavailable and local PostgreSQL not listening. No staging database was supplied. |
| `supabase migration list --remote` | Not completed | The CLI identified production project `wholesale-erp (lfajonwbfweflkymuvmx)` but returned `AccessTokenRequiredError`. No migration was applied. |

No test result is inferred from source or documentation. The E2E pass covers only the five named browser scenarios; it does not validate tenant database policies or transaction correctness.

## Existing SQL test coverage

- `supabase/tests/tenant_security.test.sql` is written for the `organization_id` contract and creates two organizations with separate authenticated users. It checks organization/customer reads, membership checks, direct ledger grants, profile admin-column access, direct membership insert, staff customer create, cross-tenant customer insert, and staff expense denial. It has not been executed.
- `supabase/tests/marketing_approval.test.sql` checks that two marketing RPC signatures exist. It does not exercise RLS isolation or approval behavior.
- `supabase/legacy-tests/` contains former `org_id`/`memberships`/`warehouses` SQL and concurrency scripts. Those files do not match the active migration schema and are not active test evidence.

## Coverage gaps requiring staging tests

| Area | Current evidence | Missing verification |
| --- | --- | --- |
| Tenant isolation | One unrun two-tenant SQL script | SELECT/INSERT/UPDATE/DELETE across every tenant table, organization settings leakage, cross-tenant foreign keys, RPC reads/writes, platform-admin negative test. |
| Organization roles | Source policies and one unrun staff assertion | Owner/admin/manager/staff action matrix on every plan, plus SECURITY DEFINER RPC enforcement. |
| Purchase/receiving | Unit-level weighted-average math only | Purchase order must not change stock; repeated and partial receipts; receipt rollback; supplier invoices/GRNI; duplicate/concurrent receiving. |
| Sales/POS | Unit-level calculations and five UI E2E tests | Server-side price validation; cash/credit/partial amounts; exact-once stock; retry after lost response; concurrent last-unit sale; reversal and refund. |
| Customer payment | Pure allocation arithmetic unit tests | Per-invoice cap, payment cap, customer ownership, cross-tenant rejection, concurrent allocation, idempotent retry, reversal. |
| Supplier payment | No DB integration test | Advance vs invoice allocation, outstanding cap, duplicate/concurrent payment, reversal audit. |
| Stock/report reconciliation | No active SQL transaction fixture suite | Movement ledger vs per-branch balances/valuation after purchase, sale, adjustment, transfer, return, and reversal. |
| Financial reports | Report pages/views exist in source | Independent source-to-report assertions for daily/monthly sales, gross profit, receivables, payables, cash/bank, Asia/Yangon date boundary. |
| Backup/restore | RPC definitions and JSON merge path | Snapshot integrity, restore idempotency, no overwrite of posted ledgers, cross-org rejection, recovery from verified backup. |

## Test conclusion

Frontend/static checks are green. Database confidence remains insufficient for a pilot because no SQL integration test, transaction workflow test, or report reconciliation test could be executed. The missing tests above are release gates, not optional coverage polish.
