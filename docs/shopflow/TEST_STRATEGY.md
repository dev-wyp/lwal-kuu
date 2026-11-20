# ShopFlow Test Strategy

## Test tiers

### Unit

Test pure domain calculations: line totals/discounts/tax, weighted average cost, payment allocation and advances, return quantity caps, account transfers/fees, double-entry balance, inventory movement reconciliation, MMK formatting, `Asia/Yangon` date boundaries and report grouping.

### Database integration

Run only on disposable local/dedicated staging databases. Tests use rollback fixtures and two organizations. Never run fixture SQL against production.

- RLS and grants: member/nonmember, staff/manager/owner, platform admin, anon and service role; include settings, profiles, direct writes, views and definer RPCs.
- Transaction RPCs: sale validation/idempotency/branch stock; receipt ownership/replay/partial quantities; customer/supplier allocation bounds and same-party ownership; transfer/adjustment; reversal/return.
- Concurrency: two checkouts for limited stock, concurrent allocation of one invoice, concurrent receipt and transfer, idempotent duplicate requests.
- Integrity: composite-FK rejection, deferred/unvalidated legacy row handling, journal balance/closed period, immutability, rollback on each injected invalid line.
- Backup/restore: tenant export isolation, version/schema rejection, duplicate handling, no posted-row overwrite, restore audit and integrity checks.
- Report reconciliation: source sales/purchases/payments/movements/journals equal report totals.

### Playwright E2E

Critical workflows: organization registration/onboarding, product/customer/supplier creation, purchase receipt, retail and wholesale sale, partial receipt/payment, credit advance allocation, supplier payment, return/refund, transfer, expense, reports/export, subscription entitlement, and two-tenant UI isolation. Use a dedicated test project and test identities only.

## Current automated coverage

- `tests/unit/business-logic.test.mjs`: weighted-average examples, gross profit, FIFO allocation.
- `tests/unit/marketing-logic.test.mjs`: marketing metrics, workflow guards, retry, OAuth state and attribution.
- `tests/e2e/lwal-kuu.spec.ts`: public landing/pricing, auth validation, marketing auth redirect, pricing periods, public viewport overflow.
- `supabase/tests/tenant_security.test.sql` and `marketing_approval.test.sql`: checked-in DB scripts; not run in this workspace.
- `supabase/tests/p0_transaction_integrity.test.sql`: includes supplier full/partial payment, multi-invoice allocation, advances, idempotent retry, amount/invoice over-allocation rejection, cross-tenant rejection, rollback, and audit assertions; not run without disposable PostgreSQL.
- `docs/shopflow/PHASE_B_STAGING_VERIFICATION.md`: provides a two-session concurrent supplier-payment protocol. Supplier reversal SQL remains blocked because no reversal RPC/ledger contract exists yet.
- `supabase/tests/tenant_security.test.sql`: must run alongside the P0 transaction suite after a clean disposable migration replay.

## Baseline and latest local verification

- Before P0 edits: `npm test` passed existing unit and five E2E tests; build/lint passed.
- After POS, customer-payment, and supplier-payment frontend edits: `npm test` passed (unit suites and 5/5 E2E); build and lint passed.
- SQL integration: NOT RUN. The local Docker/PostgreSQL runtime was unavailable in the prior inspection. No production SQL was run.

## CI gates

1. `npm run lint`
2. `npm run build`
3. `npm run test:unit`
4. `npm run test:e2e` on local Vite, with controlled server binding
5. Clean migration replay on disposable PostgreSQL/Supabase
6. Upgrade migration replay from a data-bearing staging snapshot
7. All SQL security/transaction tests and two-tenant tests
8. Report reconciliation and backup/restore drill

Record command, commit, database version, seed version, exit code and sanitized artifacts. A frontend-only pass must not imply DB or production verification.

