# Inventory Improvements

**Status:** Existing stock ledger, weighted-average cost and branches/transfers are implemented in source. Physical counts, aging and damage workflows are partial or missing. Production behavior is unverified.

## Existing foundation

- `stock_movements` is the quantity ledger; `product_stock_balances` and `branch_stock_balances` calculate current balances.
- Purchase receiving, sale confirmation, adjustments and branch transfers create movements.
- P0 migration `0043` scopes sale stock checks to the selected branch, adds tenant-aware constraints for core stock references, and scopes receipt product updates to the owning organization. Supplier payment workflows in `0044` use the purchase payable balance but do not replace the stock ledger.
- Never mutate a balance cache or product stock field without a corresponding movement.

## Ordered improvements

1. **Reconcile current ledgers:** verify opening balances, movement type semantics, negative stock policy and branch mapping in a disposable database.
2. **Physical stock counts:** create count session, expected quantity snapshot, counted quantity, variance, reason, counter, approver, and posted status. Posting creates adjustment movements; editing posted counts is prohibited.
3. **Valuation:** make cost layers/snapshots consistent. Existing global average cost must be reconciled with branch stock; branch valuation must not multiply or misattribute the shared product average.
4. **Reorder suggestions:** tenant/branch reorder point, lead-time demand and suggested order quantity; recommendation is advisory, purchase order remains a separate approved action.
5. **Aging/slow-moving:** derive from immutable movement history using `Asia/Yangon` business dates; disclose missing opening history.
6. **Damaged/write-off:** reason, condition, disposition, approval and audit; post a negative movement and corresponding accounting event.
7. **Unit conversion (optional):** product-specific conversion graph with a canonical base unit and precision rules. Store transaction quantity and base quantity snapshots so later conversion edits do not change history.
8. **Batch/expiry/serial (optional):** add lot/serial-level balances and expiry workflow only after core purchase/sales movements are stable. Plan gates must be enforced in RPCs as well as UI.
9. **Branch reconciliation:** compare per-branch balances to organization aggregate and ensure every sale/receipt/adjustment/transfer has a branch.

## Controls and tests

- Advisory lock key and row lock strategy must be consistent across sale, adjustment, transfer and receipt operations.
- Cross-tenant product/branch references are rejected by composite FKs and RPC checks.
- Validate nonnegative stock where business policy requires it, with concurrency tests.
- Reconcile `opening + purchase + return + adjustment + transfer-in - sale - supplier-return - write-off - transfer-out` to current stock.
- Verify average cost against movement quantities/cost snapshots and test zero/negative historical stock edge cases.
- Test concurrent branch sales, transfer versus sale, duplicate receipt, count approval, and rollback.

