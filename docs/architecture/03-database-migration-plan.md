# Lwal Kuu — Database Migration Plan

## 1. Migration Strategy & Ordering

All database modifications follow strict dependency ordering. Migrations are placed under `supabase/migrations/` and execute as a forward-only idempotent sequence.

```
0001_core_and_tenancy.sql
  ├── Creates public extensions (pgcrypto, uuid-ossp)
  ├── Defines profiles, organizations, organization_members, organization_settings, audit_logs
  ├── Defines RLS security functions: has_org_membership(), get_user_org_role(), is_platform_admin()
  └── Sets up profiles trigger on auth.users creation

0002_product_catalog.sql
  ├── Defines product_categories, units, products
  ├── Enforces organization-scoped unique constraints (sku, code, name)
  └── Implements RLS policies for Catalog

0003_customers_and_suppliers.sql
  ├── Defines customers and suppliers
  └── Implements RLS policies for CRM

0004_inventory_and_costing.sql
  ├── Defines stock_movements (immutable ledger) and stock_adjustments
  ├── Implements weighted average cost calculation triggers/functions
  ├── Creates reconcilable current stock view (product_stock_balances)
  └── Implements RLS policies for Inventory

0005_purchasing_and_payables.sql
  ├── Defines purchases, purchase_items, supplier_payments
  ├── Implements atomic RPC: receive_purchase_order()
  ├── Implements atomic RPC: record_supplier_payment()
  └── Implements RLS policies for Purchasing

0006_sales_and_receivables.sql
  ├── Defines sales, sale_items, payments, payment_allocations
  ├── Implements atomic RPC: confirm_sale()
  ├── Implements atomic RPC: record_customer_payment_and_allocate()
  ├── Implements atomic RPC: void_or_reverse_sale()
  └── Implements RLS policies for Sales & Cash

0007_expenses_and_finance.sql
  ├── Defines expense_categories, expenses
  └── Implements RLS policies for Expenses

0008_subscriptions_and_limits.sql
  ├── Defines plans, subscriptions, subscription_events, usage_limits
  ├── Implements subscription lifecycle RPCs (start_trial, upgrade_plan, verify_manual_payment)
  ├── Implements limit enforcement guards (check_tenant_limit)
  └── Seeds baseline plans (Starter, Business, Pro)

0009_reporting_views.sql
  ├── Creates customer_ledger_view (opening + sales - payments)
  ├── Creates supplier_ledger_view (opening + purchases - payments)
  ├── Creates gross_profit_view
  └── Creates daily_sales_summary_view
```

---

## 2. Row Level Security (RLS) Baseline

Every tenant-scoped table enables RLS:
```sql
ALTER TABLE public.<table_name> ENABLE ROW LEVEL SECURITY;
```

Standard access policies:
1. **SELECT:** Permitted if `has_org_membership(organization_id)` returns true.
2. **INSERT:** Permitted if user is member with appropriate role (`owner`, `admin`, `manager`, or `staff` depending on table).
3. **UPDATE:** Permitted for non-confirmed/non-posted records with appropriate role.
4. **DELETE:** Prohibited for financial/ledger records. Prohibited for confirmed transactions. Allowed only for drafts by admin/owner.

---

## 3. Database Functions & Atomic RPC Specifications

### 3.1 `confirm_sale(p_org_id, p_sale_id, p_payment_method, p_amount_paid, p_idempotency_key)`
- **Execution:** `SECURITY DEFINER` with fixed `search_path`.
- **Validation:**
  - Verifies caller membership in `p_org_id`.
  - Checks if `p_idempotency_key` was already processed.
  - Ensures sale status is `'draft'`.
  - Validates stock availability for each item in `sale_items`.
- **State Changes (Atomic Transaction):**
  1. Locks sale row: `SELECT * FROM sales WHERE id = p_sale_id FOR UPDATE`.
  2. Computes total sale price and total cost using current `average_cost` of each product.
  3. Inserts negative movements into `stock_movements` (`movement_type = 'sales_out'`).
  4. Updates sale status to `'confirmed'`, sets `total_cost`, `paid_amount`, and calculates `payment_status` (`'paid'`, `'partial'`, or `'unpaid'`).
  5. If `p_amount_paid > 0`:
     - Creates record in `payments`.
     - Creates record in `payment_allocations` allocating payment to this sale.
  6. Increments monthly sales count in `usage_limits`.
  7. Inserts record in `audit_logs`.
  8. Returns updated sale JSON.

### 3.2 `receive_purchase(p_org_id, p_purchase_id, p_items_json, p_amount_paid, p_payment_method)`
- **Validation:**
  - Caller role must be `owner`, `admin`, or `manager`.
  - Purchase status must be `'draft'` or `'ordered'`.
- **State Changes:**
  1. Computes new weighted average cost for each item:
     $$NewAvgCost = \frac{(CurrentStock \times CurrentAvgCost) + (ReceivedQty \times PurchaseCost)}{CurrentStock + ReceivedQty}$$
  2. Updates `products.average_cost` and `products.purchase_price`.
  3. Inserts positive movements into `stock_movements` (`movement_type = 'purchase_in'`).
  4. Marks purchase status as `'received'`.
  5. If `p_amount_paid > 0`, logs a `supplier_payments` record.
  6. Returns received purchase record.

### 3.3 `record_customer_payment(p_org_id, p_customer_id, p_amount, p_payment_method, p_allocations_json, p_idempotency_key)`
- **Validation:**
  - Caller role is verified.
  - Total allocated amount must not exceed `p_amount`.
  - Each target sale must belong to `p_org_id` and have remaining unpaid balance.
- **State Changes:**
  1. Inserts record into `payments`.
  2. For each allocation in `p_allocations_json`:
     - Inserts record into `payment_allocations`.
     - Updates `sales.paid_amount` and recalculates `sales.payment_status`.
  3. Logs audit entry.
  4. Returns payment with allocation details.

### 3.4 `void_or_reverse_sale(p_org_id, p_sale_id, p_reason)`
- **Validation:**
  - Caller must be `owner` or `admin`.
  - Sale must be `'confirmed'`.
- **State Changes:**
  1. Marks sale status as `'reversed'` or `'voided'`, records `void_reason` and `voided_at`.
  2. Inserts compensatory positive movements in `stock_movements` (`movement_type = 'sale_reversal'`).
  3. If payment was recorded and allocated, marks allocations as reversed and creates customer credit.
  4. Records `audit_logs` entry.

