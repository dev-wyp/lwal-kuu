# Plan feature gap matrix

**Verification update (2026-11-20):** The Phase B review checked the current source only. The plan SQL matrix was not executed; no assignment, limit, entitlement, or production row is newly certified. Coverage and test states are summarized in [PHASE_B_TEST_STATUS_AND_MATRICES.md](PHASE_B_TEST_STATUS_AND_MATRICES.md). Migration `0044` remains blocked on actual allocation-schema evidence; the dependency and evidence report is [PHASE_B_MIGRATION_DEPENDENCY_AND_COMPATIBILITY_REPORT.md](PHASE_B_MIGRATION_DEPENDENCY_AND_COMPATIBILITY_REPORT.md).

**Evidence date:** 2026-11-19. This is a source-code audit, not live production verification.  
`✓`/`—` assignments are the default matrix encoded by migrations 0019/0031; existing production rows were not queried. Tests were not executed. No production query or migration was run for this audit.

## How to read the matrix

Each plan section contains every one of the 42 boolean features and all five limits. `Complete`, `Partial`, and `Missing` describe local source evidence only. `Not tested` and `Unverified` are actual evidence statuses. `Final` uses the strict release definition: an entry is compliant only if source, workflow, entitlement, relevant database enforcement, tests, and production behavior are all verified. As no SQL/E2E tests or live production verification were run, no row is marked release-compliant. For a disabled feature, `N/A` means no workflow is promised by that plan; denial behavior itself remains unverified.

**Evidence references:** `M19` = migration 0019; `M27` = 0027 subscription hardening; `M30` = barcode entitlement; `M31` = complete feature matrix; `M32` = report views; `M33` = support/audit; `M35/38` = plan-gated notification queue/delivery; `M36/37` = branches/transfers; `M39` = backup/restore; `M40/41` = advanced roles; `M42` = tenant security; `M43/44` = transaction and supplier payment workflow. `UI` means the named React pages/components. Relevant tests are listed after the plan tables.

## Starter

| Feature / limit | Pricing assignment | Frontend | Backend | Database enforcement | Workflow | Tests | Production | Final |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Product Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Category Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Customer Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Supplier Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Purchase Management | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Sales Management | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Cash Sales | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Credit Sales | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Partial Payments | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Customer Ledger | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Customer Debt Tracking | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Supplier Payables | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Payment & Receipt Management | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Expense Management | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Inventory Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Stock Adjustment | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Stock Transfer | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Low Stock Alerts | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Advanced Inventory | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Barcode Support | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| QR Support | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Multi-Branch | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Daily Sales Report | Enabled (M19/31) | Complete (UI) | Complete (M32/45) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Basic Product Report | Enabled (M19/31) | Complete (UI) | Complete (M32/45) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Monthly & Yearly Reports | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Customer Statement PDF | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Supplier Statement PDF | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Sales Analytics | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Purchase Analytics | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Branch Reports | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Profit & Loss Report | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Cash Flow Report | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Profit Estimation | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Automated Reports | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Debt Reminders | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Manual Data Export | Enabled (M19/31) | Complete (UI) | Complete (browser CSV) | Tenant-scoped report reads; export is client-side | Complete for active report | Not tested | Unverified | Non-compliant |
| Excel Export | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Basic User Permissions | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Advanced Permissions | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Audit Logs | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Backup & Restore | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Priority Support | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Active users (1) | Limit 1 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; advisory lock (M27) | Complete; active membership counted | Not tested | Unverified | Non-compliant |
| Active products (100) | Limit 100 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; advisory lock (M27) | Complete; active products counted | Not tested | Unverified | Non-compliant |
| Active customers (100) | Limit 100 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; advisory lock (M27) | Complete; active customers counted | Not tested | Unverified | Non-compliant |
| Active suppliers (20) | Limit 20 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; advisory lock (M27) | Complete; active suppliers counted | Not tested | Unverified | Non-compliant |
| Branches (1) | Limit 1 (M19/31) | Complete indicator (UI) | Partial: branch migration 0036 reported failing in prod | Complete in source (M36), production unknown | Default branch plus active branch count | Not tested | Unverified | Non-compliant |

## Business

| Feature / limit | Pricing assignment | Frontend | Backend | Database enforcement | Workflow | Tests | Production | Final |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Product Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Category Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Customer Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Supplier Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Purchase Management | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Sales Management | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Cash Sales | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Credit Sales | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Partial Payments | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Customer Ledger | Enabled (M19/31) | Complete (UI) | Complete in source after M45 view/RPC plan and customer-view role checks | Complete in source after M45; migration not applied/verified | Complete locally; DB behavior untested | Not tested | Unverified | Non-compliant |
| Customer Debt Tracking | Enabled (M19/31) | Complete (UI) | Complete for debt/balance data | Partial: entitlement is not proven on every read path | Complete UI workflow; API denial unproven | Not tested | Unverified | Non-compliant |
| Supplier Payables | Enabled (M19/31) | Complete (UI) | Partial: M45 gates summary/table reads; payment RPC source exists, 0044 schema conflict reported | Partial: M45 read gates; 0044 effective schema not verified | Partial: production posting path unverified | Not tested | Unverified; 0044 blocker | Non-compliant |
| Payment & Receipt Management | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete for customer payment RPC; supplier path partial (M44) | Complete for customer receipts; supplier payment unresolved | Not tested | Unverified | Non-compliant |
| Expense Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (feature trigger) | Complete | Not tested | Unverified | Non-compliant |
| Inventory Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Stock Adjustment | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Stock Transfer | Enabled (M19/31) | Complete (UI) | Complete RPC (M36) | Complete in source (M36) | Complete locally; migration reported failing in production | Not tested | Unverified; 0036 blocker | Non-compliant |
| Low Stock Alerts | Enabled (M19/31) | Partial: configuration/visibility limited | Partial: jobs queue outbox messages | Partial: enqueue plan-gated; delivery not DB-verified | Partial: queued; dispatch/configuration required | Not tested | Unverified | Non-compliant |
| Advanced Inventory | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Barcode Support | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| QR Support | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Multi-Branch | Enabled (M19/31) | Complete (UI) | Complete branch and transfer code (M36/37) | Complete in source (M36/37) | Complete locally; production migration failure reported | Not tested | Unverified; 0036 blocker | Non-compliant |
| Daily Sales Report | Enabled (M19/31) | Complete (UI) | Complete (M32/45) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Basic Product Report | Enabled (M19/31) | Complete (UI) | Complete (M32/45) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Monthly & Yearly Reports | Enabled (M19/31) | Complete (UI) | Complete (M32/45) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Customer Statement PDF | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Supplier Statement PDF | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Sales Analytics | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Purchase Analytics | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Branch Reports | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Profit & Loss Report | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Cash Flow Report | Disabled | N/A | N/A | M45 denial predicate in source; pending execution | N/A | Not tested | Unverified | Non-compliant |
| Profit Estimation | Enabled (M19/31) | Complete (POS UI) | Complete from average cost (sales RPC/UI) | Partial: not verified as authoritative posted gross profit | Complete for estimate before sale; estimate only | Not tested | Unverified | Non-compliant |
| Automated Reports | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Debt Reminders | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Manual Data Export | Enabled (M19/31) | Complete (UI) | Complete (browser CSV) | Tenant-scoped source reads; export client-side | Complete for active report | Not tested | Unverified | Non-compliant |
| Excel Export | Enabled (M19/31) | Partial: current report only | Partial: HTML `.xls`, not native `.xlsx` | Tenant-scoped source reads; export client-side | Partial spreadsheet export | Not tested | Unverified | Non-compliant |
| Basic User Permissions | Enabled (M19/31) | Complete (fixed roles) | Complete for core role checks | Partial coverage across all endpoints unverified | Complete basic staff workflow | Not tested | Unverified | Non-compliant |
| Advanced Permissions | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Audit Logs | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Backup & Restore | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Priority Support | Disabled | N/A | N/A | Denial unverified | N/A | Not tested | Unverified | Non-compliant |
| Active users (3) | Limit 3 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; advisory lock (M27) | Complete; active membership counted | Not tested | Unverified | Non-compliant |
| Active products (2,000) | Limit 2,000 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; advisory lock (M27) | Complete; active products counted | Not tested | Unverified | Non-compliant |
| Active customers (Unlimited) | Limit -1 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; -1 means unlimited | Complete | Not tested | Unverified | Non-compliant |
| Active suppliers (Unlimited) | Limit -1 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; -1 means unlimited | Complete | Not tested | Unverified | Non-compliant |
| Branches (2) | Limit 2 (M19/31) | Complete indicator (UI) | Partial: branch migration 0036 reported failing in prod | Complete in source (M36), production unknown | Default plus active branch count | Not tested | Unverified; 0036 blocker | Non-compliant |

## Pro

| Feature / limit | Pricing assignment | Frontend | Backend | Database enforcement | Workflow | Tests | Production | Final |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Product Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Category Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Customer Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Supplier Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Purchase Management | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Sales Management | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Cash Sales | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Credit Sales | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Partial Payments | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete in source (M27/43) | Complete | Not tested | Unverified | Non-compliant |
| Customer Ledger | Enabled (M19/31) | Complete (UI) | Partial: access mainly gated in React/report query | Partial: plan denial on every direct read path not established | Complete UI workflow; API denial unproven | Not tested | Unverified | Non-compliant |
| Customer Debt Tracking | Enabled (M19/31) | Complete (UI) | Complete for debt/balance data | Partial: entitlement is not proven on every read path | Complete UI workflow; API denial unproven | Not tested | Unverified | Non-compliant |
| Supplier Payables | Enabled (M19/31) | Complete (UI) | Partial: payment RPC source exists; 0044 schema conflict reported | Partial: 0044 effective schema not verified | Partial: production posting path unverified | Not tested | Unverified; 0044 blocker | Non-compliant |
| Payment & Receipt Management | Enabled (M19/31) | Complete (UI) | Complete (M27/43) | Complete for customer payment RPC; supplier path partial (M44) | Complete for customer receipts; supplier payment unresolved | Not tested | Unverified | Non-compliant |
| Expense Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (feature trigger) | Complete | Not tested | Unverified | Non-compliant |
| Inventory Management | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Stock Adjustment | Enabled (M19/31) | Complete (UI) | Complete (M27) | Complete in source (M27) | Complete | Not tested | Unverified | Non-compliant |
| Stock Transfer | Enabled (M19/31) | Complete (UI) | Complete RPC (M36) | Complete in source (M36) | Complete locally; migration reported failing in production | Not tested | Unverified; 0036 blocker | Non-compliant |
| Low Stock Alerts | Enabled (M19/31) | Partial: configuration/visibility limited | Partial: jobs queue outbox messages | Partial: enqueue plan-gated; delivery not DB-verified | Partial: queued; dispatch/configuration required | Not tested | Unverified | Non-compliant |
| Advanced Inventory | Enabled (M19/31) | Complete (UI) | Complete for costing/history | Partial: distinct entitlement-specific checks not evident for every operation | Complete core inventory; advertised feature boundary overlaps existing inventory | Not tested | Unverified | Non-compliant |
| Barcode Support | Enabled (M19/31) | Complete (UI + supported scanner/camera) | Complete (product code persistence) | Complete in source (M30 trigger) | Complete for scanner/manual entry; camera depends on browser | Not tested | Unverified | Non-compliant |
| QR Support | Enabled (M19/31) | Partial: camera needs browser `BarcodeDetector` | Complete for QR code persistence | Complete in source (M34 trigger) | Partial where browser lacks supported decoder | Not tested | Unverified | Non-compliant |
| Multi-Branch | Enabled (M19/31) | Complete (UI) | Complete branch and transfer code (M36/37) | Complete in source (M36/37) | Complete locally; production migration failure reported | Not tested | Unverified; 0036 blocker | Non-compliant |
| Daily Sales Report | Enabled (M19/31) | Complete (UI) | Complete (M32/45) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Basic Product Report | Enabled (M19/31) | Complete (UI) | Complete (M32/45) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Monthly & Yearly Reports | Enabled (M19/31) | Complete (UI) | Complete (M32/45) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Customer Statement PDF | Enabled (M19/31) | Complete print flow | Complete from tenant statement data | Tenant scoping; feature read denial not proven for every direct path | Complete via browser print-to-PDF | Not tested | Unverified | Non-compliant |
| Supplier Statement PDF | Enabled (M19/31) | Complete print flow | Partial: depends on payables/payment data path | Partial: supplier entitlement paths not fully verified | Partial due unresolved 0044 payment schema | Not tested | Unverified | Non-compliant |
| Sales Analytics | Enabled (M19/31) | Complete (UI) | Complete (M32/45 views) | Plan predicate in M45 source; pending execution | Complete for selected date range metrics | Not tested | Unverified | Non-compliant |
| Purchase Analytics | Enabled (M19/31) | Complete (UI) | Complete (M32/45 view) | Plan predicate in M45 source; pending execution | Complete locally | Not tested | Unverified | Non-compliant |
| Branch Reports | Enabled (M19/31) | Complete (UI) | Complete branch view (M36/45) | Plan predicate in M45 source; pending execution | Complete locally; prod migration unverified | Not tested | Unverified; 0036 blocker | Non-compliant |
| Profit & Loss Report | Enabled (M19/31) | Partial: operating P&L presentation | Partial: sales, COGS, recorded expenses only | M45 plan predicate in source; accounting reconciliation incomplete | Partial: not a full accounting P&L | Not tested | Unverified | Non-compliant |
| Cash Flow Report | Enabled (M19/31) | Partial: cash movement summary | Partial: selected receipts, walk-in sales, payments, expenses | M45 plan predicate in source; bank ledger reconciliation incomplete | Partial: not a complete cash flow statement | Not tested | Unverified | Non-compliant |
| Profit Estimation | Enabled (M19/31) | Complete (POS UI) | Complete from average cost | Partial: estimate is not a posted/reconciled profit ledger | Complete for pre-sale estimate only | Not tested | Unverified | Non-compliant |
| Automated Reports | Enabled (M19/31) | Partial: no complete customer delivery controls | Partial: scheduled summary enqueue | Partial: plan-gated queue; delivery depends on dispatch/configuration | Partial: automated generation, not proven automatic delivery | Not tested | Unverified | Non-compliant |
| Debt Reminders | Enabled (M19/31) | Partial: admin outbox operation | Partial: overdue queue and deduplication (M35/38) | Partial: entitlement on queue only; delivery config unverified | Partial: no proven autonomous delivery/opt-out/retry | Not tested | Unverified | Non-compliant |
| Manual Data Export | Enabled (M19/31) | Complete (UI) | Complete (browser CSV) | Tenant-scoped source reads; export client-side | Complete for active report | Not tested | Unverified | Non-compliant |
| Excel Export | Enabled (M19/31) | Partial: current report only | Partial: HTML `.xls`, not native `.xlsx` | Tenant-scoped source reads; export client-side | Partial spreadsheet export | Not tested | Unverified | Non-compliant |
| Basic User Permissions | Enabled (M19/31) | Complete (fixed roles) | Complete for core role checks | Partial coverage across all endpoints unverified | Complete basic staff workflow | Not tested | Unverified | Non-compliant |
| Advanced Permissions | Enabled (M19/31) | Complete (UI) | Complete for configured modules (M40/41) | Partial: all-table/all-RPC scope needs direct-role tests | Partial pending complete bypass verification | Not tested | Unverified | Non-compliant |
| Audit Logs | Enabled (M19/31) | Complete activity view | Complete audit trigger coverage in source (M33/40/41) | Complete in source for listed tables; effective install unverified | Complete for listed audited operations | Not tested | Unverified | Non-compliant |
| Backup & Restore | Enabled (M19/31) | Complete JSON export/merge UI | Partial: same-tenant merge only; excludes auth/subscription/payment config | Partial: merge validation exists (M39); full recovery semantics absent | Partial; not point-in-time/full-system recovery | Not tested | Unverified | Non-compliant |
| Priority Support | Enabled (M19/31) | Complete ticket UI | Partial: ticket and admin reply flow; no measured SLA | Complete source membership/plan RLS (M33) | Partial: priority service level not established | Not tested | Unverified | Non-compliant |
| Active users (10) | Limit 10 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; advisory lock (M27) | Complete; active membership counted | Not tested | Unverified | Non-compliant |
| Active products (Unlimited) | Limit -1 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; -1 means unlimited | Complete | Not tested | Unverified | Non-compliant |
| Active customers (Unlimited) | Limit -1 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; -1 means unlimited | Complete | Not tested | Unverified | Non-compliant |
| Active suppliers (Unlimited) | Limit -1 (M19/31) | Complete indicator (UI) | Complete (M27) | Complete in source; -1 means unlimited | Complete | Not tested | Unverified | Non-compliant |
| Branches (5) | Limit 5 (M19/31) | Complete indicator (UI) | Partial: branch migration 0036 reported failing in prod | Complete in source (M36), production unknown | Default plus active branch count | Not tested | Unverified; 0036 blocker | Non-compliant |

## Test mapping and outstanding plan tests

| Suite | Existing coverage found | Status |
| --- | --- | --- |
| `supabase/tests/p0_transaction_integrity.test.sql` | Supplier/customer allocations, cross-tenant references, over-allocation, same-key equivalence and changed-payload rejection, advances, audit rows, rollback, and transaction behavior | Not executed: Docker unavailable; sandbox blocks PostgreSQL shared memory |
| `supabase/tests/tenant_security.test.sql` | Two-organization RLS, membership/role permission checks, unauthorized tenant write | Not executed |
| `supabase/tests/plan_feature_matrix.test.sql` | All 42 stored assignments, all five normalized/legacy limits, runtime decisions for all three tiers, custom-plan independence, current resource usage, expired-subscription denial, and direct Starter membership quota rejection | Not executed; concurrent quota race still needs a two-session test |
| `tests/unit/plan-presentation.test.mjs` | Cumulative/custom feature display, limit fallback, and savings calculation | Passed via `npm run test:unit` |
| `tests/e2e/lwal-kuu.spec.ts` | Public pricing navigation, basic form validation, billing cycle display and calculated savings, cumulative feature display, plan trial registration, auth redirects, public page responsive widths | Six tests exist in source; not executed; does not cover signed-in subscription/feature entitlements |
| Required next SQL suite | Runtime plan allow/deny for each tier; concurrent limit creation; inactive/reactivation; upgrade; downgrade retention and over-limit behavior; expiration/grace/override; custom plans; branches; feature-specific support/backup checks | Not present as a passing result |
| Required next Playwright suite | Public pricing vs signed-in subscription matrix and limits; monthly/yearly exact values; trial state; manual payment submission/approval; upgrade/downgrade; feature denial messages; mobile/tablet/desktop signed-in layouts | Not present as a passing result |

## Counts and interpretation

- Catalogue size: 42 boolean features plus 5 limits.
- Enabled boolean entries: Starter 12, Business 26, Pro 42 (80 advertised feature-plan entries total). Numeric limits are shown separately in each plan section and are not included in the 80-feature compliance percentage.
- Source-only workflow estimate from the audit: Starter 12/12, Business 22/26, Pro 31/42. These figures treat known partial feature workflows as incomplete; they do not award test or production verification.
- Strict verified compliance: 0/95 advertised plan entries (80 enabled boolean entries and 15 plan limits), because SQL/E2E results and production-effective plan/database state are unavailable. This is a release evidence result, not a claim that the UI/backend source is absent.

## Local pricing implementation progress (2026-11-19)

- Public and signed-in plan pages now share feature-section rules: show “Includes all [previous] features” only if the enabled set is a superset, and list all included features for a non-cumulative/custom tier.
- Both pages now resolve each limit from `plan_feature_limits` first, then legacy plan columns, then “Not configured”.
- Yearly savings copy is derived from the selected plan’s stored monthly/yearly price; no price data was changed.
- Pricing cards and registration show the selected plan’s configured trial duration; onboarding success copy no longer promises a fixed 14 days.
- The unsupported two-hour manual subscription review claim was removed from the signed-in payment dialog.
- Added migration 0045 to gate direct customer/supplier balance-view reads, customer payments/allocations, and supplier payment reads by plan, and require ledger entitlement, customer-view role permission, and same-organization customer ownership for the customer statement RPC. Added disposable SQL assertions for Business allow, Starter direct-call denial, cross-organization customer rejection, and Pro role denial.
- Added `plan_feature_matrix.test.sql` to check all 42 standard-tier boolean assignments and all five normalized/legacy limits.
- Added migration 0046 so runtime limit resolution matches the pages (normalized row, then legacy plan column, then zero/unconfigured if neither exists). Configured `-1` remains unlimited. Extended the plan suite with runtime RPC, custom-plan, and a direct quota-rejection case. Neither SQL migration nor SQL suite has been applied/executed.
- Closed a `SECURITY DEFINER` role-permission bypass in the customer statement RPC by requiring `customers:view`, and added a Pro staff denial assertion to the disposable tenant-security suite. SQL remains unexecuted.
- Applied the same plan and role checks to direct customer payment and allocation table reads; expanded tenant-security fixtures so Business can read its own receipts while Starter cannot bypass the ledger entitlement through base tables. SQL remains unexecuted.

## Customer workflow compatibility progress (2026-11-20)

- Customer management and POS now load customer identity rows from `public.customers`; ledger balances are fetched from the separately gated summary view only when the plan includes customer ledger/debt tracking. Starter cash-sale customer selection remains available without displaying a fabricated zero balance.
- Dashboard receivables totals are now fetched and displayed only when the organization has a ledger entitlement. This keeps a plan-gated view from appearing as a real zero balance on Starter.
- Build, unit suite, and lint passed after this change. SQL and browser integration coverage remain unexecuted.
- Added local plan predicates to daily/product/monthly/yearly/purchase/P&L/cash-flow and branch report views, plus branch stock view, so direct view queries use the same entitlement keys as their UI gates. The SQL suite now checks those view definitions. Migration 0045 and SQL assertions remain unapplied/unexecuted.

## P0 transaction-integrity progress (2026-11-20)

- Customer payment retry keys are now bound to a normalized request fingerprint, including invoice allocations and payment metadata. Same-key concurrent retries serialize; changed requests fail. Existing un-fingerprinted rows use a strict comparison against their stored allocations and payment fields.
- Added SQL regression assertions for equivalent retry, changed allocation/notes rejection, and exactly-once effects. Migration 0047 remains local and SQL is not run; this row remains release-unverified.
- `npm run build` and `npm run test:unit` passed. Playwright and SQL suites remain unexecuted, so test and production results above remain unchanged.
