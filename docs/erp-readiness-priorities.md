# ERP readiness priorities

This status is based on the checked-in UI, migrations, and documentation. It is not a production database verification. “Partial” means the UI or data path exists but end-to-end reconciliation, operational controls, or environment verification is missing.

| Priority | Required outcome | Status | Evidence / remaining work |
| --- | --- | --- | --- |
| P0 | One authoritative schema | Partial | `supabase/migrations/0001`–`0042` is now the repository contract and `schema_unified.sql` is generated from it. The hosted project's schema/history has not been inspected, and local `project_id` differs from the production project ref previously reported. |
| P0 | Verified membership and role permissions | Partial | Migration `0042` adds restrictive write policies, baseline manager/staff permissions across all plans, trigger checks for security-definer RPC writes, protected platform-admin fields, RPC-only tenant creation, and RPC-only posted ledgers. It has not been applied to or exercised against a database. |
| P0 | RLS tests with two organizations | Partial | `supabase/tests/tenant_security.test.sql` is written against the current `organization_id` schema. It cannot be reported as passing until run on a disposable Supabase database. |
| P0 | Verified transactional RPCs and migration history | Partial | Purchase receipt, sale posting/reversal, payment allocation, and stock adjustment RPCs exist in source. Live migration history and rollback behavior have not been verified. |
| P0 | Backup and staging deployment process | Partial | A safe sequence is documented in `supabase/README.md`; no current backup or staging deployment was performed. |
| P1 | Products and stock management | Implemented in source | Product catalog, stock movements, adjustments, balances, and branch stock controls exist. Database integration tests remain unrun. |
| P1 | Purchase and goods receiving | Partial | Purchase creation and transactional receiving exist. Full supplier invoice/payable reconciliation and correction workflow still need end-to-end database verification. |
| P1 | POS and sales history | Implemented in source | POS, sale history, confirmation, and stock deduction exist. End-to-end consistency remains unverified against a database. |
| P1 | Cash, bank, and credit sales | Partial | Cash and credit sale flows exist. A reconciled cash/bank account ledger and bank reconciliation are not established by the current source. |
| P1 | Customer payments and outstanding balances | Partial | Payment allocation and outstanding summaries exist. Reconciliation between every source payment and reported balance is not verified. |
| P1 | Supplier payments and outstanding balances | Partial | Supplier payment and payables screens/data paths exist. Supplier invoice/liability and reversal coverage need end-to-end validation. |
| P1 | Transaction corrections and reversals | Partial | Sale reversal exists. A complete correction/reversal path for all purchasing, payment, expense, and inventory transactions is not established. |
| P2 | Daily and monthly sales | Implemented in source | Daily and monthly report views/pages exist; they have not been reconciled against transaction fixtures in the current schema. |
| P2 | Current stock and valuation | Partial | Stock balance and valuation reports exist in source; reconciliation after receiving, sale, adjustment, transfer, and reversal remains untested. |
| P2 | Customer and supplier outstanding | Partial | Summary views/pages exist; allocation and reversal reconciliation remains unverified. |
| P2 | Gross profit | Partial | Gross profit is derived from sales and cost fields, but costing/reversal test coverage and report reconciliation are incomplete. |
| P2 | Cash and bank movement | Partial | Cash flow summary exists, but no complete bank account ledger/reconciliation workflow is present. |
| P2 | Reconcile reports to source transactions | Missing verification | Add fixture-based SQL assertions that independently total source transactions and compare all report outputs after the full workflow. |
| P3 | Trial registration and onboarding | Partial | Atomic onboarding RPC and trial setup exist in source. The UI fallback to unsafe direct writes was removed; RPC behavior is not DB-tested. |
| P3 | Basic plan limits | Implemented in source | Plan entitlements and limit enforcement migrations exist; deployed feature assignments and boundary behavior need live/staging verification. |
| P3 | Manual subscription payment verification | Partial | Subscription management paths exist; operator review and payment verification should be exercised as a repeatable workflow. |
| P3 | Customer support and issue tracking | Implemented in source | Support ticket request and platform admin triage/reply paths exist; delivery/response operations need service-level validation. |
| P3 | Repeatable demo and sales process | Missing | No repeatable demo dataset, demo script, qualification checklist, or customer handoff procedure is established in the repository. |

## Next release gate

Do not treat P0 as complete until the intended Supabase project is confirmed, a backup is verified, the chain is applied to staging, the two-tenant RLS suite passes, and transaction/report reconciliation checks pass against that same schema. The workspace cannot run those checks at present because its local PostgreSQL and Docker services are unavailable.
