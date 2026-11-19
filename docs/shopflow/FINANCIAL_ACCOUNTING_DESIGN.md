# Financial Accounts and Accounting Design

**Status:** Design baseline only. No financial-account or double-entry accounting schema is implemented in migrations `0001`–`0044`.

## Design boundaries

- Existing `payments`, `supplier_payments`, and `expenses` store transaction method text but are not a cash/bank account ledger.
- Existing report views are operational summaries; do not label them accrual financial statements.
- Maintain MMK as organization default and use `Asia/Yangon` for business-day cutoffs; keep amounts in precise PostgreSQL numeric types.
- Every table is organization-scoped, RLS-protected, and connected through tenant-aware references.

## Financial accounts and cashbook

Proposed entities (new additive migration after review):

- `financial_accounts`: organization, name, type (`cash`, `bank`, `mobile_wallet`, `clearing`), currency, opening balance/date, status.
- `account_transactions`: immutable debit/credit movement, account, date/time, amount, source document, reference, creator, reversal reference and audit metadata.
- `account_transfers`: transfer header, from/to accounts, amount, fee, reference, approval/posting state; post equal-and-opposite account movements, with fee represented as an expense.
- `cashier_shifts`: branch/cash account, opened/closed by, opening cash, expected cash, counted cash, difference, status and audit events.
- Bank statement import and match records must retain original statement identifiers and import checksum for deduplication.

Transfers are balance-sheet movements, never income or expense. Cash count variance posts to an explicitly configured variance account after approval.

## Double-entry accounting

Proposed entities:

1. `chart_of_accounts` with tenant-unique code, type, normal balance, and active state.
2. `accounting_periods` with date bounds and open/closed state.
3. `journal_entries` with source reference, posting date, status (`draft`, `approved`, `posted`, `reversed`), creator/approver/poster, and reversal reference.
4. `journal_entry_lines` with organization, journal, account, debit/credit, optional branch/customer/supplier dimensions.
5. `journal_audit_events` for immutable transitions.

Posting RPC requirements:

- Require authenticated membership and a role permission for the organization.
- Lock the target period and journal; require an open period.
- Require at least two lines, nonnegative debit/credit values, and exact equal totals after currency precision.
- Reject both-sided nonzero line values unless explicit supported semantics are defined.
- Validate every account and dimension belongs to the organization.
- Post atomically and prevent direct UPDATE/DELETE of posted rows.
- Correct errors using a linked reversing entry; preserve source document identifiers.

## Source-document posting map (proposal)

| Source event | Debit | Credit |
| --- | --- | --- |
| Cash sale | Cash/receivable | Sales revenue and tax payable, if configured |
| Cost of goods sold | Cost of goods sold | Inventory |
| Customer receipt | Cash/bank | Accounts receivable or customer advance liability |
| Purchase received | Inventory | Accounts payable |
| Supplier payment | Accounts payable / supplier advance | Cash/bank |
| Expense | Expense account / input tax | Cash/bank or payable |
| Inter-account transfer | Destination account | Source account; fee separately expense |
| Return/refund | Return/allowance and inventory/COGS correction | Cash/receivable/payable as appropriate |

This mapping requires tax, inventory-cost and customer/supplier advance policies to be approved before posting is built. Do not backfill historical journals from assumptions.

## Reports and reconciliation

- Trial balance requires total debits equal total credits for posted, non-reversed journals.
- General ledger is a journal-line view with period and branch dimensions.
- Statement of financial position and profit/loss use the chart-of-accounts hierarchy and accounting period.
- Cash flow statement classifies account movements; transfers between cash accounts are eliminated from operating/investing/financing flows.
- AR/AP aging uses invoice due dates and posted allocations/credit notes.
- Existing cash-basis summaries remain separately labeled until they reconcile to accrual entries.

## Acceptance criteria

- Double-entry balance, closed-period rejection, source ownership, cross-tenant rejection, idempotent posting, reversal correctness and report reconciliation have database integration tests.
- Opening balances are represented as dated source journals, not hidden mutable totals.
- Migration compatibility is checked against existing data before constraints or backfills.

