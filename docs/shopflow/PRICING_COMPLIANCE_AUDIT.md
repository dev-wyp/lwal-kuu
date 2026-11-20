# Pricing plan compliance audit

**Audit date:** 2026-11-19  
**Scope:** Local repository source, migrations, UI, workflow code, and checked-in tests for Starter, Business, and Pro.  
**Production status:** Unverified. This audit did not connect to Supabase or run production queries. Operator-provided logs previously reported migration 0036/0044 failures; these are recorded as reported evidence, not independently confirmed live state.

**Verification update (2026-11-20):** No pricing/entitlement SQL matrix was executed in this Phase B review. `supabase/tests/plan_feature_matrix.test.sql` contains assertions for all 42 boolean assignments, all five normalized/legacy limit values, standard-tier runtime decisions, custom-plan independence, current usage, expiry, and an over-limit Starter membership insert. Coverage and outstanding cases are listed in [PHASE_B_TEST_STATUS_AND_MATRICES.md](PHASE_B_TEST_STATUS_AND_MATRICES.md). Treat every database case as NOT RUN, and keep production values and effective enforcement UNVERIFIED. Prices and advertised assignments were not changed.

## Decision summary

The advertised tier matrix is defined in `0019_plan_feature_system.sql` and completed for missing rows by `0031_complete_plan_feature_matrix.sql`. Source assignments are cumulative: Starter has 12 boolean features, Business 26, and Pro all 42. The five usage limits are 1/3/10 users, 100/2,000/unlimited products, 100/unlimited/unlimited customers, 20/unlimited/unlimited suppliers, and 1/2/5 branches.

**Strict release compliance: 0/95 advertised plan-feature entries verified (0%).** This counts 80 enabled boolean feature-plan entries plus 15 plan limit entries. No entry meets the full bar of working workflow, correct enforcement, passed relevant tests, and verified production state. It does not mean the source code implements nothing. The source-only estimate is 80/95 entries (84.2%) with no known functional gap, while 15 boolean entries have a partial or material enforcement/workflow gap; all source-only estimates still need database tests and production verification. Not-included boolean entries are evaluated as expected denials, not counted in the 95 advertised entries.

| Plan | Advertised feature entries | Source-only complete estimate | Strict release verified | Decision |
| --- | ---: | ---: | ---: | --- |
| Starter | 17 (12 features + 5 limits) | 17/17 (100%) | 0/17 (0%) | Not ready: tests and production state unverified |
| Business | 31 (26 features + 5 limits) | 27/31 (87.1%) | 0/31 (0%) | Not ready: partial customer/supplier entitlement enforcement, alerts and export gaps; tests and production unverified |
| Pro | 47 (42 features + 5 limits) | 36/47 (76.6%) | 0/47 (0%) | Not ready: reports, automation, backup, support, QR and supplier workflow gaps; tests and production unverified |

The source-only estimate is intentionally conservative and counts the known partial cases listed below as incomplete; it counts the five limits per plan as implemented in source, not as tested. It is not a test result or a production claim.

## Pricing and subscription consistency

- `PricingPage.tsx` and `SubscriptionPage.tsx` obtain plan prices and feature assignments from database plan records and normalized feature tables. No production values were queried, so actual displayed plan state cannot be confirmed.
- Local implementation after review: both pages now apply the same normalized-limit-first, legacy-column fallback rule for all five limit features. Production row consistency remains unverified.
- Local implementation after review: both pages now use one shared helper to show a previous-tier inclusion statement only when the current enabled feature set is a superset of the immediately previous displayed plan. Non-cumulative/custom plans display their complete enabled feature set without a false inheritance claim.
- Local implementation after review: the fixed “Save 16%” label was replaced by a percentage calculated from each plan’s stored monthly/yearly prices (rounded to a whole percent). No price values were changed.
- The subscription flow submits manual payment for administrator review. The UI says review occurs within two hours, but no enforceable SLA was found in the reviewed subscription flow. No separate downgrade workflow or downgrade impact preview was found.
- Local implementation after review: both plan lists and registration now display the selected plan's `trial_days`; onboarding confirmation no longer hard-codes 14 days. Production trial values and expiry behavior remain unverified.

## Entitlement, database, and lifecycle findings

1. `FeatureGate` and `useEntitlements` use `get_organization_entitlements`; protected routes and many page actions use those values. They are UI protections, not sufficient on their own to stop direct API calls.
2. `0027_subscription_flow_hardening.sql` adds feature/limit RPCs, several table triggers, restrictive read policies, and advisory locks for active user/product/customer/supplier limit checks. Migration 0036 adds branch limit enforcement. The code must be present and effective in the target database for those checks to apply; production status has not been queried.
3. Database plan enforcement is not uniform across all catalogue features. Some features gate UI/report reads, while writes and data reads are protected only where a trigger/RLS/view/RPC specifically checks the feature. The matrix identifies source-level coverage and gaps; direct API tests are required.
4. Local migration 0046 aligns runtime limit resolution with both pricing pages: normalized value first, legacy plan column fallback, and zero/unconfigured only if neither source exists. Explicit `-1` remains unlimited. This migration and its SQL regression assertions are not applied or executed.
5. Plan overrides are checked before subscription status in `check_organization_feature`; an enabled override may grant a feature after normal subscription expiry. Confirm intended policy and test explicit expiration/override cases.
6. The limit triggers serialize relevant active-record creation with an organization/resource advisory lock. Source supports concurrent limit protection for users, products, customers, suppliers, and branches, but no SQL concurrency test was run. Soft-deactivation releases capacity; downgrade does not delete active records, so existing over-limit records can remain while further activation/creation is rejected.
7. Subscription payment approval sets the selected plan and period, but no over-limit downgrade validation or customer-facing retention/blocked-create explanation was found. Upgrade/downgrade, expired status, grace period, overrides, and custom plans need SQL and UI regression coverage.
8. `0031` fills missing standard tier rows while preserving pre-existing rows, and defaults newly discovered custom-plan features to disabled. Existing standard rows can differ from the defaults because they are intentionally not overwritten. Production plan rows and custom-plan behavior are unverified.
9. Source contract in 0044 does not match the operator-reported pre-existing supplier allocation table: reported errors say `organization_id` and then `supplier_payment_id` are missing. Local 0044 preflight checks required columns and aborts with a clear error; this is a blocker until a read-only schema diagnostic is compared with the migration proposal. Do not treat supplier payments as production-ready.

## Priority feature findings

| Feature | Source finding | Business impact / release gap |
| --- | --- | --- |
| Customer Ledger | Local migration 0045 now gates the balance view by ledger/debt entitlement and the statement RPC by entitlement, membership, and same-organization customer ownership. Disposable SQL assertions were added but not executed; production remains unverified. | Do not count this as fixed in an effective database until migration 0045 and direct API tests are verified. |
| Supplier Payables | Local migration 0045 gates the supplier balance view and direct supplier payment reads by `supplier_payables`. Payment UI/RPC exists; the operator-reported 0044 allocation schema failure is unresolved in production. | Supplier balances/payments cannot be considered available or safe in production until the actual table contract, migration history, constraints, and SQL tests are verified. |
| Low Stock Alerts | Scheduled functions queue notifications, and an outbox trigger checks plan entitlements. Delivery path is operator/admin dispatch through configured email integration rather than a confirmed autonomous delivery service. | “Get notified” is only partially met until scheduled delivery and failure/retry monitoring are verified. |
| Automated Reports | Daily/weekly jobs enqueue summaries; plan checks exist. Dispatch relies on an admin operation and configured Resend delivery. | Queuing is not equivalent to reliably delivered automatic reports; expose delivery status and verify schedule/dispatch. |
| Debt Reminders | Overdue balances are grouped and deduplicated before enqueueing; entitlement check exists. Delivery depends on outbox dispatch/configuration. | Reminder workflow is partial pending automatic delivery, retry, opt-out, and audit verification. |
| Backup & Restore | Pro-only JSON backup and merge RPCs exist. Restore merges records; it is not a point-in-time database backup and excludes auth/subscription/payment configuration. | Advertised name may imply stronger recovery than provided. Clarify product wording or implement and test a complete recovery process. |
| Profit & Loss | Report view aggregates confirmed sales, cost of goods, and recorded expenses. | This is operating P&L, not a complete ledger-based profit-and-loss statement; adjustments, taxes, and other income/cost classes may be absent. |
| Cash Flow | Summary is computed from selected receipt, walk-in sale, supplier payment, and expense records. | It is not a full cash/bank ledger or reconciliation; bank transfers and opening/closing balances are not established. |
| Advanced Permissions | UI and 0040/0041 policies/triggers implement module rights, with reads restricted for selected operational views/tables. | Coverage must be confirmed for all sensitive tables/RPC paths. Existing test suite does not prove role-by-role API bypass denial. |
| Priority Support | Ticket creation, admin triage, and replies exist. | No response-time SLA or measured priority handling was found; “Priority” should be operationally backed or described more narrowly. |
| Barcode / QR | Barcode fields and scanner are entitlement-gated; camera decoding depends on browser `BarcodeDetector` support. QR scanning shares that browser capability constraint. | QR/browser fallback and scanner workflows need cross-browser tests; QR support is partial where camera decoding is unavailable. |
| Multi-Branch | Branch, transfer, branch reports, and stock controls exist in migrations and UI. | Operator logs report 0036 failing in production due schema/RPC conflicts. The feature is not production-verified; local SQL tests must cover branch inventory and tenant isolation. |
| Excel Export | Reports export HTML tables with `.xls` filename; only the currently selected report is exported. | Excel-readable file is not a native `.xlsx` workbook and the feature coverage is narrow. Advertise as spreadsheet export or implement tested workbook export. |

## Test evidence

- `supabase/tests/p0_transaction_integrity.test.sql` contains transaction, customer payment allocation, and supplier payment checks including retry, over-allocation, cross-tenant rejection, unallocated advances, audit rows, and rollback. **Not executed in this audit.**
- `supabase/tests/tenant_security.test.sql` contains two-tenant RLS and role permission assertions. **Not executed in this audit.**
- `supabase/tests/plan_feature_matrix.test.sql` now asserts all 42 feature assignments and five normalized/legacy limits, runtime decisions for Starter/Business/Pro, custom-plan independence, current resource usage, expired-subscription denial, and direct Starter membership quota rejection. **Not executed.** A concurrent two-session quota race test remains outstanding.
- Local migration 0045 now embeds the corresponding feature predicate in report and branch views, and adds plan/role restrictions to customer and supplier ledger reads. The SQL suite checks the view predicates and direct allow/deny behavior, but remains unexecuted; this is not evidence of deployed enforcement.
- Local migration 0047 binds customer payment idempotency keys to the complete normalized request and rejects changed-payload retries. Its SQL assertions are present but could not be run without a disposable database; no release status is changed.
- `tests/unit/plan-presentation.test.mjs` covers cumulative/custom plan display, normalized/legacy limit fallback, and yearly savings calculation. **Passed** via `npm run test:unit`.
- `tests/e2e/lwal-kuu.spec.ts` now has six Playwright tests in source, including assertions for calculated yearly savings and cumulative plan feature display. It does not cover the signed-in subscription/upgrade/downgrade flows, per-plan denials, or API bypass. **Not executed.**
- No passed plan matrix SQL or signed-in subscription Playwright suite is evidenced by this source review. Do not mark any case “Pass”.

## Recommended implementation order

1. Resolve production-state uncertainty with authorized read-only project/migration/plan-matrix diagnostics. Do not push migrations to production.
2. Reconcile the existing supplier payment allocation schema with 0044, then validate the additive migration in a disposable database using the P0 and tenant suites plus supplier payment scenarios.
3. Add SQL entitlement-denial and concurrent-limit tests; cover expiration, override, downgrade retention, upgrade, custom plan, and direct API/RPC paths.
4. Close plan data consistency issues: normalize limits for both pricing pages; define custom-plan copy semantics; correct the yearly discount text; document trial and downgrade behavior.
5. Establish reliable outbox delivery for low-stock, automated reports, and debt reminders with retry/failure visibility; or narrow pricing wording.
6. Align report and backup claims with their accounting/recovery scope; close any selected-table/RPC permission gaps; test QR fallbacks and spreadsheet compatibility.
7. Run staging regression, browser/mobile subscription tests, and operator-run production read-only verification. Only then reassess launch readiness.

## Files reviewed and next changes

Reviewed: `docs/plan-feature-matrix.md`, `docs/plan-feature-implementation-audit.md`, pricing/subscription/gating/admin plan UI, migrations 0019–0044, transaction and tenant SQL suites, and the six-test Playwright source suite.

Implemented locally after the audit was reviewed: shared plan display helpers in `src/modules/subscription/planPresentation.ts`, matching normalized/legacy limit resolution and cumulative-feature copy on both pricing pages, calculated savings labels, plan-driven trial duration in pricing/registration/onboarding, removal of the unsupported two-hour manual-review promise, pricing Playwright assertions, migration 0045 direct ledger/payables view and table read gates, migration 0046 runtime normalized/legacy limit parity with fail-closed behavior when neither value exists, SQL assertions for plan allow/deny and same-tenant customer ownership, and a stored/runtime plan matrix plus quota regression suite. Browser and database tests have not been run; production was not queried.

Next implementation targets are feature-specific pages/RPCs named in the gap matrix, plus SQL entitlement/limit and authenticated subscription E2E coverage. Modify migration 0044 only after actual supplier schema diagnostics. Production deployment remains out of scope.
