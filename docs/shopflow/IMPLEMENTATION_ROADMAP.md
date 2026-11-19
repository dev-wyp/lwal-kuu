# ShopFlow V1.0 Implementation Roadmap

**Updated:** 2026-11-19  
**Source:** [Feature gap audit](FEATURE_GAP_AUDIT.md), existing audit reports, architecture notes, and direct local source review.  
**Release position:** NOT READY until P0 transaction/security work is locally verified, replayed and tested in staging, and production state is confirmed by an authorized operator. Operator logs report `0043` applied and `0044` failed because the deployed `supplier_payment_allocations` relation has a different schema; this has not been independently verified from remote migration history.

## Delivery order and exit gates

| Phase | Scope | Exit gate |
| --- | --- | --- |
| A | Feature audit and baseline | Gap matrix links findings to evidence; unit/E2E/build/lint baseline recorded |
| B | P0 transaction integrity and tenant security | Hardened sale, payment, receiving, tenant boundaries, backup restore and definer grants; additive migration; SQL regression tests; local replay and two-tenant staging tests |
| C | Sales/purchase returns and receiving | Append-only return documents, partial quantities, stock disposition, refund/credit notes and purchase GRNs; integration/E2E flows pass |
| D | Financial accounts and cash/bank | Account ledger, transfers, cashbook, statement import/matching and reconciliation with transfer neutrality |
| E | Accounting foundation | Double-entry COA, periods, journals, posting/reversal, GL, trial balance and statements reconcile to source documents |
| F | Inventory improvements | Count/approval, valuation/aging/reorder, damage/write-off and branch reconciliation; all changes ledger-backed |
| G | POS operations | Cashier shifts, cash difference, split tenders, reprint/refund/discount approval and barcode paths |
| H | Reports and analytics | Date/branch/timezone filtering, exports, printable reports and source-to-report reconciliation tests |
| I | SaaS and automation | Entitlement consistency, renewal/payment lifecycle, outbox retries/deduplication/monitoring and scheduler privilege proof |
| J | Backup, restore and auditability | Versioned tenant export, preview/validation, immutable posted ledgers, integrity check and restore audit |
| K | Types and developer experience | Generated types from validated staging schema; no invented types; docs synchronized |
| L | Release readiness | Clean migration replay and staging upgrade, full test suite, security review, backup/restore drill, operational runbooks and approved production release |

## P0 work items (start here)

1. **Sale RPC:** organization-scoped idempotency; authenticated actor; explicit membership and permission; active branch ownership/access; server-read sale lines and products; reject invalid quantities/discounts/payment methods; server-derived subtotal/total/tax; validate tender; lock product/stock rows in stable order; ensure availability; preserve cost snapshots; atomic sale/payment/allocation/stock/audit writes; stable response on retry.
2. **Customer payments:** require same-org customer and confirmed same-customer sales; validate JSON shape and positive amounts; cap aggregate allocation at payment amount and each sale outstanding; row-lock affected invoices in deterministic order; support unallocated advances; use organization-scoped idempotency; return stable retry response; define reversal as compensating ledger records.
3. **Purchase receipt and supplier payments:** validate active manager permission, purchase/supplier/branch/product tenants; receive only remaining quantity; record cumulative GRN/receipt quantities; avoid replay; compute weighted average from a consistent stock valuation basis; update products with organization predicate; validate upfront payment and invoice payable; add supplier payment RPC with idempotency and advances/reversal design.
4. **Tenant integrity:** inventory live/source relationships; add organization-aware uniqueness/FKs only after a read-only mismatch assessment; use additive `NOT VALID` FK then validation only when existing data remediation is planned; audit every SECURITY DEFINER function and role grants; correct settings policy and cron entry points; protect initial platform admins through an approved operator process.
5. **Restore integrity:** reject overwrite of posted sale/payment/allocation/stock rows; restore immutable records only when IDs/payloads are identical, or create explicit audited compensating operations; validate ownership before import.
6. **Regression evidence:** expand disposable DB tests for two tenants, duplicate retries, cross-customer/tenant references, partial receiving, oversells, over-allocation and rollback. The current workspace cannot run SQL tests without a local PostgreSQL/Supabase test target.

### P0 feature matrix

| Feature | Existing Status | Required Action | Priority | Database | Backend | Frontend | Tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Sale confirmation | NEEDS SECURITY FIX | Replace trust of client header totals with authoritative recalculation, scoped idempotency and locked stock | P0 | Additive function/index migration after duplicate-key audit | `confirm_sale()` | Retain UI payload, handle stable retry | SQL boundary/concurrency and E2E |
| Customer payments | NEEDS SECURITY FIX | Validate customer/invoice ownership and amount ceilings, idempotency and advances | P0 | Add payment uniqueness/constraints after compatibility review | Replace RPC logic atomically | Add result/error affordance; remove client as authority | SQL boundary/concurrency/rollback |
| Purchase receipt | NEEDS SECURITY FIX | Tenant-safe incremental receiving/weighted cost | P0 | Receipt/GRN support migration | Harden `receive_purchase`; payment RPC | Partial receiving dialog | SQL receipt replay and cross-tenant tests |
| Supplier payments | PARTIAL / MIGRATION BLOCKED ON EXISTING SCHEMA | Inspect the deployed allocation relation, then adapt migration without creating a parallel table; verify idempotent partial payments, payable limits, advances, and later allocation/reversal | P0 | Migration 0044 has a compatibility preflight and cannot proceed until the existing table shape is known | `record_supplier_payment_and_allocate()` | Supplier payment dialog with FIFO/manual allocation | SQL balance/concurrency tests blocked |
| Organization settings RLS | NEEDS SECURITY FIX | Replace broad permissive read; validate all effective policies/grants | P0 | Additive policy migration | Check helper functions | None unless access flow changes | Two-org RLS SQL test |
| Cross-tenant references | NEEDS SECURITY FIX | Org-aware FK/checks after data compatibility assessment | P0 | Composite unique/FK constraints in incremental migrations | Validate all RPC joins/writes | None expected | Cross-org FK/RPC tests |
| Cron RPCs | NEEDS SECURITY VERIFICATION | Revoke client execution on global workers; preserve deliberate guarded admin paths | P0 | Explicit grant migration | Confirm scheduler/service execution | Admin action keeps authorization | ACL catalog test and role invocation tests |
| Backup restore | NEEDS SECURITY FIX | Prevent overwrite of posted business history | P0 | Additive restore version/policy migration if needed | Replace conflict-update semantics | Preview and conflict UI | Restore immutability tests |
| Platform admin bootstrap | NEEDS SECURITY FIX | Review production assignments against approved allowlist before any correction | P0 | No automatic account mutation | Approved guarded admin process | None | Allowlist test only after authorized roster |

## Remaining implementation backlog by phase

### C — Sales and purchasing

- Sales return/credit note with reason, return approval, quantity caps, restock/damaged disposition, customer credit/refund and audit.
- Purchase returns with supplier credit/refund, payable adjustments and traceable stock-out movements.
- PO states and GRN history; supplier invoice reference, partial receipts, cancellation rules and outstanding quantities.

### D–E — Cash and accounting

- Keep payment method labels separate from financial accounts; each transfer has two equal-and-opposite account movements plus optional fee.
- Add cashbook open/close, bank reconciliation status/history, and transaction matching.
- Implement balanced journals; posted journals immutable; use reversal entries; close accounting periods; retain source document references.
- Clearly label existing summary outputs cash-basis unless they are reconciled to accrual postings.

### F–H — Inventory, POS, reporting

- Count sessions and approval with adjustment movements; reorder/safety stock, aging, damaged/write-off and branch reconciliation.
- Optional batch/expiry/serial/unit-conversion only after core single-unit and ledger behavior is stable; gate by entitlements only after backend enforcement.
- Cashier shifts and expected-vs-actual cash; split tenders and approval permissions; barcode device behavior; no offline POS promise until idempotent sync/conflict resolution exists.
- Reports must agree with source transaction and journal totals, use `Asia/Yangon` periods, support branch/date filters, and export CSV/Excel/print layouts.

### I–L — SaaS, operations, types and release

- Validate plan entitlements at every backend write path, then add subscription transition tests and history.
- Deliver notifications from an outbox with retry/backoff, idempotency, dead-letter review, scheduler-only global RPC access and job monitoring.
- Distinguish tenant export/import from provider-level database backup and disaster recovery; test restore from a backup.
- Generate DB types from the staging schema after migration replay; do not treat manually reconstructed `schema_unified.sql` as deployed truth.
- Do not deploy to production until migration ledger, effective ACL/RLS catalog, staging two-tenant tests, rollback/restore procedures and approval are recorded.

## Baseline (before implementation)

- Unit suite: PASS.
- Playwright E2E: 5/5 PASS after allowing local Vite to bind port 3000.
- TypeScript/Vite build: PASS.
- ESLint: PASS.
- SQL integration tests: NOT RUN; local database runtime unavailable.
- Production migration history and effective grants: BLOCKED pending authorized read-only access; operator logs report 0043 applied and 0044 failed. The allocation relation catalog query is required before safely adapting 0044.

## Current phase status

- Phase A audit and roadmap: complete as local source artifacts.
- Phase B: local migrations 0043–0044, RPC changes, POS/payment retry behavior, supplier payment UI and SQL regression script created; implementation is not certified. Production migration 0044 is blocked on read-only inspection of the existing allocation-table schema. Database integration remains blocked until disposable local/staging Postgres is available, then staging verification is still required.
- Phases C–L: not started; follow the above dependency order.

