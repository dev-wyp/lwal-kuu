# Cross-tenant reference review

**Status:** Static source review only. Live constraints, legacy rows, and RPC definitions were not queried from production. No constraints or functions were changed.

## Finding X-01 — Core tenant FKs do not bind the organization ID

- **Severity:** Critical
- **Evidence:** Across migrations `0002`, `0004`, `0005`, `0006`, `0007`, and `0036`, tenant rows carry `organization_id`, while references such as `product_id`, `customer_id`, `supplier_id`, `sale_id`, `purchase_id`, and `branch_id` generally reference only the referenced row's global `id`. The chain contains no composite FK of the form `(organization_id, referenced_id) -> parent(organization_id,id)` for the core business relationships reviewed.
- **Affected tables/functions:** Relationships listed below; security-definer routines that act on the referenced rows.
- **Business impact:** A valid global FK does not prove the referenced business row belongs to the same tenant. Cross-organization links can pass constraints and become dangerous in privileged RPCs, reports, or exports.
- **Recommended correction:** Add parent unique keys on `(organization_id,id)` and child composite foreign keys after auditing/backfilling existing rows. Retain globally unique IDs if needed, but enforce tenant ownership at the relational boundary.
- **Verification procedure:** Report orphan/mismatch counts in production read-only SQL; remediate only under an approved data migration plan; then insert cross-tenant references in disposable staging and assert constraint failures.

## Affected relationships and proposed controls

| Child relationship | Current source reference | Proposed ownership control | Additional RPC validation |
| --- | --- | --- | --- |
| `products.category_id` → `product_categories.id` | Single ID FK; both rows have `organization_id` | Composite `(organization_id,category_id)` FK; also constrain category parent links by tenant | Validate category belongs to product organization on create/update/import |
| `products.unit_id` → `units.id` | Single ID FK | Composite `(organization_id,unit_id)` FK | Validate active unit belongs to organization |
| `purchases.supplier_id` → `suppliers.id` | Single ID FK | Composite `(organization_id,supplier_id)` FK | Validate supplier tenant and active status at order creation |
| `purchases.branch_id` → `branches.id` | `0036` adds single `branch_id` FK | Composite `(organization_id,branch_id)` FK | Existing trigger checks branch organization/activity; verify effective trigger and all update paths |
| `purchase_items.purchase_id` → `purchases.id` | Single ID FK | Composite `(organization_id,purchase_id)` FK | Validate purchase is editable and line org matches parent |
| `purchase_items.product_id` → `products.id` | Single ID FK | Composite `(organization_id,product_id)` FK | `receive_purchase` must filter/validate both item and product organization before cost update |
| `supplier_payments.supplier_id` → `suppliers.id` | Single ID FK | Composite `(organization_id,supplier_id)` FK | Validate payment supplier equals purchase supplier when linked |
| `supplier_payments.purchase_id` → `purchases.id` | Single ID FK, nullable | Composite `(organization_id,purchase_id)` FK | Check purchase supplier and remaining recognized payable |
| `sales.customer_id` → `customers.id` | Single ID FK, nullable | Composite `(organization_id,customer_id)` FK | Validate customer at sale creation and confirmation |
| `sales.branch_id` → `branches.id` | `0036` adds single `branch_id` FK | Composite `(organization_id,branch_id)` FK | Existing trigger checks branch organization/activity; verify database definition |
| `sale_items.sale_id` → `sales.id` | Single ID FK | Composite `(organization_id,sale_id)` FK | Validate parent sale state and matching org before line mutation |
| `sale_items.product_id` → `products.id` | Single ID FK | Composite `(organization_id,product_id)` FK | `confirm_sale` must validate product tenant and server-side price/quantity |
| `payments.customer_id` → `customers.id` | Single ID FK, nullable | Composite `(organization_id,customer_id)` FK | Validate customer tenant before recording payment |
| `payment_allocations.payment_id` → `payments.id` | Single ID FK | Composite `(organization_id,payment_id)` FK | Validate payment belongs to same customer and tenant |
| `payment_allocations.sale_id` → `sales.id` | Single ID FK, nullable | Composite `(organization_id,sale_id)` FK | Validate sale customer matches payment customer; cap payment and invoice allocation |
| `stock_adjustments.product_id` → `products.id` | Single ID FK | Composite `(organization_id,product_id)` FK | Current adjustment RPC checks product ID and organization; retain this server check |
| `stock_adjustments.branch_id` → `branches.id` | `0036` adds single FK | Composite `(organization_id,branch_id)` FK | Retain branch organization/activity check |
| `stock_movements.product_id` → `products.id` | Single ID FK | Composite `(organization_id,product_id)` FK | Verify every sale/receipt/transfer/reversal producer and branch mapping |
| `stock_movements.branch_id` → `branches.id` | `0036` adds single FK | Composite `(organization_id,branch_id)` FK | Retain branch membership check |
| `stock_transfers.source_branch_id`, `destination_branch_id` → `branches.id` | Same-tenant checks in transfer RPC; single FK structure | Composite tenant FKs if columns permit; otherwise trigger constraint | RPC already looks up both branches by `p_org_id`; verify effective function and direct writes |
| `stock_transfer_items.transfer_id` → `stock_transfers.id` | Single ID FK | Composite `(organization_id,transfer_id)` FK | Validate transfer tenant before insert |
| `stock_transfer_items.product_id` → `products.id` | Single ID FK | Composite `(organization_id,product_id)` FK | Transfer RPC checks product organization; verify direct writes cannot bypass |
| `expenses.category_id` → `expense_categories.id` | Single ID FK, nullable | Composite `(organization_id,category_id)` FK | Validate category belongs to expense tenant |
| `stock_movements.reference_type/reference_id` | Polymorphic reference, no ordinary FK | Add typed reference validation trigger or split typed FK columns/tables | Validate referenced sale/purchase/adjustment/transfer tenant for every movement type |

This is the set of cross-tenant relationships identified in the core business migrations; validate it against production catalog and all marketing/subscription relationships before designing a migration.

## RPC-specific findings

### X-02 — Purchase receipt can update a foreign tenant's product row

- **Severity:** Critical
- **Evidence:** `receive_purchase` scopes the purchase header by `p_org_id`, but selects purchase items using `purchase_id` and joins products by `p.id = pi.product_id`. It then updates `public.products` using only `where id = v_item.product_id`.
- **Affected:** `purchases`, `purchase_items`, `products`, `stock_movements`; `receive_purchase(uuid,uuid,numeric,text)`.
- **Business impact:** If a tenant-owned purchase item references another organization's product, receipt processing can change that product's average cost/purchase price.
- **Recommended correction:** Validate `pi.organization_id=p_org_id`, `p.organization_id=p_org_id`, and update with both product ID and organization ID; add the composite FK.
- **Verification:** In disposable two-tenant staging, create a mismatched item as tenant A, invoke receipt, and assert rejection plus unchanged tenant B product/stock.

### X-03 — Sale idempotency lookup is not scoped to tenant

- **Severity:** High
- **Evidence:** `confirm_sale` looks up `sales` by `idempotency_key` before it selects the requested sale using `id` and `organization_id`. The idempotency column is globally unique in source.
- **Affected:** `sales`; `confirm_sale(uuid,uuid,text,numeric,text)`.
- **Business impact:** A caller who obtains/reuses another tenant's request key may receive that sale's ID and invoice number from the RPC response.
- **Recommended correction:** Scope idempotency lookup and uniqueness to organization; verify the matched sale ID is the requested sale ID before returning a retry response.
- **Verification:** Reuse tenant B's key while authenticated only in tenant A; assert no tenant B identifiers or invoice details are returned.

### X-04 — Customer payment RPC does not bind customer, invoice, and tenant amounts

- **Severity:** Critical
- **Evidence:** The RPC inserts caller-supplied `p_customer_id`; it locks a sale by `p_org_id`, but does not check that sale's `customer_id` equals the payment customer or that allocation stays under payment/invoice balances.
- **Affected:** `payments`, `payment_allocations`, `sales`; `record_customer_payment_and_allocate(...)`.
- **Business impact:** Cross-customer allocation and over-allocation can corrupt ledgers even when the sale ID itself is same-tenant.
- **Recommended correction:** Apply both composite constraints and explicit same-customer/payment/invoice validation with row locks and caps.
- **Verification:** Cross-customer, cross-organization, over-payment, over-invoice, and concurrent allocation cases must all reject without side effects.

## Production verification blocked

The Supabase CLI confirmed the production link but could not read migration history without an access token. No live foreign-key definitions, mismatched-row counts, or function bodies were queried. Proposed constraints must not be applied until existing production rows are checked for violations and a reviewed data-preserving staging migration is prepared.
