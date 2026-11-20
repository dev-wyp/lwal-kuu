# Plan implementation roadmap

**Purpose:** Close the gaps in `PRICING_COMPLIANCE_AUDIT.md` and `PLAN_FEATURE_GAP_MATRIX.md`.  
**Gate:** The source audit has been reviewed and local implementation is underway. Production changes remain prohibited until staging and production verification criteria below are met.

## Progress after audit review (2026-11-19)

- Implemented locally: pricing and signed-in subscription screens now share cumulative feature display rules, normalized/legacy limit fallback, plan-driven trial duration, and price-derived yearly savings labels. Registration displays the selected plan's trial duration, onboarding no longer hard-codes it, and the unsupported two-hour manual-review promise was removed.
- Added public pricing Playwright assertions for included feature presentation, configured trial duration, and yearly savings.
- Added migration 0045 to enforce ledger/payables entitlements on direct balance-view and supplier payment-table reads and the customer statement RPC, plus disposable SQL assertions for Business allow, Starter denial, and cross-organization customer rejection. This remains blocked from production verification until 0044's real schema mismatch is resolved and the local SQL suite is run.
- Added migration 0046 to align runtime limit fallback with plan pages and fail closed only when neither normalized nor legacy values exist; expanded SQL coverage to runtime plan decisions, custom-plan independence, current usage, and a direct Starter user-limit denial. The two-session concurrent limit race test remains outstanding.
- `npm run build` passed. SQL and Playwright suites have not been run. No production database was queried or changed.
- Remaining phases below are outstanding; supplier migration work remains blocked pending verified existing-table diagnostics.

## Phase B database verification gate (2026-11-20)

- Source dependency map for migrations `0043`–`0047` and the evidence boundary are recorded in [PHASE_B_MIGRATION_DEPENDENCY_AND_COMPATIBILITY_REPORT.md](PHASE_B_MIGRATION_DEPENDENCY_AND_COMPATIBILITY_REPORT.md).
- The 0044 read-only diagnostic has been expanded to show parent composite-key prerequisites, effective table/sequence privileges, and trigger/function security metadata. It has not been executed. Capture results using [MIGRATION_0044_DIAGNOSTIC_RESULTS_TEMPLATE.md](MIGRATION_0044_DIAGNOSTIC_RESULTS_TEMPLATE.md).
- Reported migration errors remain operator-provided logs; no remote schema/history or existing row count is confirmed. Keep 0044 blocked and do not infer aliases or prepare a production-specific migration.
- The [Phase B test status and matrices](PHASE_B_TEST_STATUS_AND_MATRICES.md) record all SQL suites and concurrency checks as NOT RUN. No disposable DB or approved staging target is available, and production is not an allowed test target.
- No reversal design or implementation was started because the instruction's stop gate excludes later phases. Keep supplier reversal on the backlog.

## P0 implementation progress (2026-11-20)

- Added migration 0047 for customer-payment idempotency, with a preflight check for existing payment/allocation column types. Same-key retries now require the same normalized customer, amount, method, references, notes, and allocation list; an advisory transaction lock serializes concurrent attempts using one key. Existing payment records remain unchanged, and legacy retry keys are accepted only when stored payment/allocation data matches.
- Added customer retry regression assertions to the disposable P0 SQL suite. This is local implementation only; SQL could not run because Docker is unavailable and sandbox policy blocks local PostgreSQL shared memory (`shmget`). The configured Supabase project is production, so it was not used for tests. E2E was also withheld because no isolated Supabase backend is available.
- Still blocked: production schema/history for 0044, supplier payment reversal, SQL suite execution, and staging verification. No P1 or P2 implementation was started.

## Phase 0 — Establish the database facts

**Why first:** The pricing catalogue, permission functions, and plan matrix are database-backed. The reported supplier allocation and branch migration errors mean local source alone cannot establish what is effective in production.

1. Have an authorized operator run the existing read-only investigation pack against the approved project and return sanitized results for migration history, plan/features/limits, relevant function definitions/grants, RLS policies, and supplier allocation columns/constraints/indexes.
2. Confirm whether migrations 0036–0044 are applied, partially applied, or pending. Do not rerun production migration pushes as an audit method.
3. Confirm effective values for standard plans, custom plans, public/active flags, subscription statuses, feature overrides, and numeric limits. Do not expose credentials or customer data.
4. Keep all changes blocked if production table definitions differ from the checked-in migration assumptions. Reconcile the actual supplier allocation structure before deciding whether 0044 should extend it.

**Acceptance:** Sanitized, dated operator evidence exists; source and deployed schema are compared; there is no unresolved production migration history ambiguity.

## Phase 1 — Disposable database verification and supplier workflow

| Work item | Source targets | Required behavior | Required tests |
| --- | --- | --- | --- |
| Supplier schema compatibility | `supabase/migrations/0044_supplier_payment_workflow.sql`; `docs/shopflow/MIGRATION_0044_ROOT_CAUSE_AND_PROPOSAL.md` | Additive compatibility with actual existing table; preserve records; fail clearly on unsupported schema; never create a duplicate allocation table | Existing populated-table upgrade; migration twice/idempotency; FK/unique/index/RLS/grant checks |
| Supplier payment workflow | `src/modules/suppliers/SupplierPaymentDialog.tsx`, `SuppliersPage.tsx`, migration 0044 | Full and partial payments, allocations over multiple purchases, advances, receipt/history, idempotent retries, reversal/audit | Existing P0 SQL suite plus explicit failure rollback, concurrency, cross-tenant supplier/purchase, over-allocation and retry-key collision |
| Purchase/sales integrity | Migrations 0043/0044; `supabase/tests/p0_transaction_integrity.test.sql` | Transactional stock, receivable/payable, payment and audit updates | Execute current P0 suite on a disposable Supabase database; record exact command, schema revision, and result |

**Acceptance:** Supplier migration applies on both an empty schema and a representative disposable schema derived from sanitized diagnostics. All SQL transaction tests pass. No production migration is run as part of this phase.

## Phase 2 — Plan entitlements and resource limits

| Work item | Source targets | Required behavior | Required tests |
| --- | --- | --- | --- |
| Complete allow/deny matrix | `0027_subscription_flow_hardening.sql`, relevant feature migrations, `supabase/tests/` | Starter denies all Business/Pro entitlements; Business denies Pro-only entitlements; Pro allows assigned entries; custom plans use explicit assignments | Parameterized SQL tests for each of 42 booleans across three standard tiers plus custom plan rows; direct table and RPC requests, not only UI checks |
| Numeric limits | `get_organization_feature_limit`, `get_organization_usage`, enforcement triggers, migration 0036 branch trigger | Enforce 1/3/10 users, 100/2,000/unlimited products, 100/unlimited/unlimited customers, 20/unlimited/unlimited suppliers, 1/2/5 branches | Concurrent creates near limits; inactive-to-active transitions; deactivation; count correctness; all `-1` unlimited cases; missing-row behavior must fail closed or have a proven migration completeness invariant |
| Subscription lifecycle | `check_organization_feature`, `verify_subscription_payment`, subscription UI | Upgrade applies correct plan; downgrade retains data and prevents new over-limit items safely; expiry/grace/cancel/override policy is explicit | SQL and E2E for active, trial, expired, past due, grace period, cancellation, override start/expiry, upgrade, downgrade, approval and rejection |
| RLS and tenant safety | Existing RLS, 0041/0042, `supabase/tests/tenant_security.test.sql` | Entitlements never weaken tenant boundaries; role permissions apply on direct client calls | Run current tenant suite and add direct API coverage across all sensitive tables/views/RPCs for two organizations and each role |

**Acceptance:** All 42 boolean decisions and 5 limits have disposable-database pass results for the standard plans. No bypass path, count race, or unexplained missing plan matrix row remains.

## Phase 3 — Close incomplete feature workflows

| Priority | Feature | Smallest safe resolution | Source areas |
| --- | --- | --- | --- |
| P0 | Customer Ledger / Debt Tracking | Add explicit entitlement checks to all direct read surfaces if absent; test report views, statement data, payments and balance calculations | `CustomersPage.tsx`, `CustomerLedgerModal.tsx`, `ReportsPage.tsx`, customer balance views/policies |
| P0 | Supplier Payables | Resolve actual schema and migration 0044 first; only then verify payables data, RPC security, allocation totals and statement parity | `SuppliersPage.tsx`, `SupplierStatementModal.tsx`, `SupplierPaymentDialog.tsx`, migrations 0043/44 |
| P1 | Low Stock Alerts | Make scheduled generation and delivery automatic, with retries, failure visibility, schedule ownership, and tenant/plan tests; or state clearly that alerts are queued for manual dispatch | migrations 0035/38/43, notification outbox, delivery worker/edge function, platform dispatch UI |
| P1 | Automated Reports | Prove scheduled delivery end-to-end and add delivery settings/failure visibility; or rename promise to generated report queue | migrations 0035/38, notification delivery and settings UI |
| P1 | Debt Reminders | Add customer notification preference/opt-out, safe retry/dedup rules and delivery result visibility, then verify plan gates | migration 0035/38, outbox worker, customer communication settings |
| P1 | P&L / Cash Flow | Either restrict product wording to the actual operating summary or reconcile full journal/cash/bank entries before calling it a complete statement | migration 0032 views, `ReportsPage.tsx`, financial data model |
| P1 | Backup & Restore | Describe exact JSON export/merge semantics and limitations; add disposable restore/rollback tests. Do not present as disaster recovery unless backup retention and full restore are supplied | migration 0039, `SettingsPage.tsx` |
| P1 | Advanced Permissions | Enumerate all sensitive tables, views, and callable RPCs; add role-specific direct API negative tests and close missing gates | migrations 0040–42, policies, RPC grants, tenant security SQL suite |
| P2 | Priority Support | Implement and monitor a response target and priority queue or remove any implied SLA from descriptions | migration 0033, Support/Platform Support pages |
| P2 | QR Support | Provide a tested fallback/manual scanner option where `BarcodeDetector` is unsupported, or disclose supported browsers | `CodeScannerDialog.tsx`, `ProductModal.tsx`, migration 0034 |
| P2 | Excel Export | Add true `.xlsx` output with worksheet headers/types or rename to Excel-readable `.xls`; test formulas/escaping and each report export | `ReportsPage.tsx`, package dependencies if an XLSX writer is chosen |
| P2 | Advanced Inventory | Define the difference from base inventory in user-facing terms and ensure each paid capability is gated consistently | inventory screens, migrations 0029/0037 and entitlement checks |
| P2 | Multi-Branch | Resolve reported production migration 0036 conflict; test seeded default branch, branch isolation, POS/purchase selection, transfer rollback and reports | migrations 0036/37, `BranchesPage.tsx`, POS/purchase screens |

**Acceptance:** Every paid feature is either a completed, plan-checked workflow with integration evidence or accurately described to customers at its actual scope.

## Phase 4 — Pricing and subscription experience consistency

| Change | Target | Acceptance |
| --- | --- | --- |
| Use one normalized limit source/fallback rule | `PricingPage.tsx`, `SubscriptionPage.tsx` | Same plan data renders identical limits on public and signed-in pages, including absent/malformed rows |
| Make tier inclusion truthful for custom plans | Both pricing pages and feature display helper | Do not say “includes all previous plan features” unless actual included feature sets are supersets; test arbitrary display order |
| Correct yearly savings label | Both pages / shared pricing component | Derive savings from actual stored monthly/yearly prices, with consistent rounding; no hard-coded 16% text |
| Document manual verification and downgrade behavior | Subscription UI and onboarding/pricing terms | Trial conditions, payment review process, activation, renewal, expiry, downgrade retention and blocked actions are explicit and tested |
| Test plans from database-backed content | Playwright subscription/pricing suite | Starter/Business/Pro amounts, features, limits and billing periods match the seeded data at phone/tablet/desktop sizes |

No price value should be altered without the user’s explicit approval. Any copy or workflow changes should preserve existing subscription and transaction records.

## Phase 5 — Repeatable staging release gate

1. Use a disposable local Supabase database for iterative SQL changes. Keep test fixtures isolated and reset only disposable databases.
2. Create/update staging from the approved project process; verify its project ref before any staging push. Never point staging commands at production.
3. Apply migrations to staging only after SQL migration review; capture the migration history before and after.
4. Run `supabase/tests/tenant_security.test.sql`, `supabase/tests/p0_transaction_integrity.test.sql`, the new plan entitlement/usage limit suite, and a supplier workflow suite. Preserve output and commit hash.
5. Run Playwright public pricing tests and authenticated plan/subscription tests against staging with seeded disposable organizations for each tier and a custom plan.
6. Verify no cross-organization reads/writes, direct RPC bypass, count race, data deletion on downgrade, or false feature copy. Capture the production read-only verification pack separately; do not infer production state from staging.

## Release exit criteria

- 100% of 42 boolean assignments and all five limits verified against actual deployed plan rows.
- All advertised tier entries complete or wording revised to match the implemented workflow.
- No unresolved RLS/tenant bypass or materialized-view/direct-RPC entitlement bypass.
- SQL entitlement/limit/tenant/P0 suites pass on staging, including concurrency and migration compatibility cases.
- Public pricing and signed-in subscription pages match prices, features, limits, trial and billing rules.
- E2E pricing, subscription, feature-denial, upgrade/downgrade, and responsive checks pass.
- Production migration and effective database state verified independently by authorized read-only queries before any release decision.

## Remaining blockers

1. Live production migration history, plan rows, feature rows, limits, grants, and RLS have not been queried in this audit.
2. Supplier allocation schema mismatch reported for migration 0044 remains unresolved against verified production schema.
3. Branch migration 0036 incompatibilities were previously reported by the operator and are not independently verified as resolved.
4. SQL test suites have not been executed; test definitions do not constitute a pass.
5. Signed-in subscription and full feature matrix Playwright coverage is not present in the current five-test suite.
6. Automated notification delivery and accounting/reporting scope need product decisions or workflow completion.
