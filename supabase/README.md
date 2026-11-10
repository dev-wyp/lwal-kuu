# Wholesale ERP Supabase schema notes

The hosted project was updated with `myanmar_wholesale_erp_all_phases.sql` (confirmed read-only on 2026-10-16). The active UI is being aligned to that script's **legacy schema contract**, not the separate proposed migrations in this repository. Verified relations include `suppliers`, `purchases`, `purchase_items`, `goods_receipts`, `goods_receipt_items`, `supplier_payments`, `supplier_payment_allocations`, `stock_balances`, `stock_movements`, `branches`, and `customer_credit_profiles`.

The combined SQL script does not define supplier create/update RPCs. It enables RLS and read policies but intentionally has no direct supplier write policy. Apply [20261016000500_legacy_phase2_supplier_rpcs.sql](migrations/20261016000500_legacy_phase2_supplier_rpcs.sql) in Supabase SQL Editor to enable supplier form saves. It uses only `public.is_org_member(uuid)` and existing supplier columns; it does not create/alter business tables. It also issues `NOTIFY pgrst, 'reload schema'` so PostgREST refreshes its function cache.

Do **not** apply migrations `20261016000100` through `20261016000400` to this project. Those are a separate proposed schema and use incompatible columns/tables/RPCs. The UI compatibility pages now read the confirmed schema. Sales, stock, purchase, receiving, payment flows use the RPC names from the combined SQL. Supplier writes require migration 005 above. The combined SQL's Phase 2 `post_supplier_payment` allocates directly to purchase orders; it does not provide supplier invoices, GRNI, or a double-entry payable ledger. The UI reflects that limitation rather than querying proposed tables that are absent.

## Proposed Phase 1 contract

- `20261016000100_phase1_core_schema.sql` through `20261016000400_purchasing_receiving_supplier_payables.sql`: separate proposed Phase 1 contract. **Do not apply to the current hosted project.**
- `20261016000200_products_inventory_rpcs.sql`: organization onboarding and product create/update/deactivate plus idempotent, transactional stock adjustments. Product/stock writes are RPC-only for authenticated users; UI operations validate organization membership and roles again in PostgreSQL.
- `20261016000300_sales_transaction_rpc.sql`: safe organization-scoped document numbering and idempotent sale posting, server-side pricing, credit-limit check, transactional stock decrement, and customer collection allocation for customer-linked cash sales.
- `20261016000400_purchasing_receiving_supplier_payables.sql`: proposed supplier create/update, purchase, receipt, invoice, and liability workflows. **Not compatible with the active combined SQL contract.**
- `20261016000500_legacy_phase2_supplier_rpcs.sql`: additive supplier create/update functions that match the deployed Phase 2 suppliers table.
- `tests/phase1_inventory.test.sql`: SQL assertions for organization isolation, no direct client writes, product CRUD permissions, stock consistency/idempotency, immutable movements, server-priced sales, retry ownership, invalid payloads, and insufficient-stock rollback.
- `tests/phase1_purchasing.test.sql`: no-stock-before-receipt, 80+20 partial receipts, receipt retry, GRNI-to-AP invoice posting, payment retry/allocation, and supplier advance assertions.
- `tests/concurrent_sales.sh` and `tests/concurrent_receipts.sh`: two-session races against limited stock and remaining purchase quantity.

All four proposed SQL migrations, both SQL integration scripts, and both concurrency harnesses passed against fresh temporary PostgreSQL 14 databases with a minimal Auth-compatible schema. This validates SQL syntax and covered transaction behavior in that harness; it is **not** a Supabase CLI/Auth integration run and is not production schema verification. The Supabase CLI is available through `npx`, but this session has no authenticated CLI access token and the Docker daemon is unavailable, so neither hosted migrations nor a local Supabase stack were run.

The first four migration files remain a proposed baseline for a **separate disposable development project**, not changes for the currently deployed combined-SQL schema. The live `stock_balances` view groups legacy `stock_movements` and exposes `quantity_on_hand`; it is not the proposed multi-warehouse snapshot design.

The UI routes include `/dashboard`, `/products`, `/products/[id]`, `/inventory`, `/sales`, `/suppliers`, `/purchases`, `/purchases/[id]`, and `/supplier-payments`. Supplier and purchasing pages are adapted to the combined SQL names (`purchase_no`, `purchase_date`, `total`, `receipt_no`, `paid_at`, and payment allocations to purchases). The combined SQL has no invoice/GRNI payable workflow, supplier create/update RPC, or balanced cash/bank accounting integration. Expense operations, void/reversal workflows, customer payment UI, full ledger reconciliation, and purchase reports remain unfinished. Do not claim the complete ERP is finished.

## Local development and review

1. Install/start Docker Desktop and the Supabase CLI. Example macOS Homebrew commands: `brew install --cask docker`, open Docker Desktop and wait for its engine, then run `brew install supabase/tap/supabase`. Verify with `docker info` and `supabase --version`.
2. From this project directory, run `supabase start` to create a disposable local Supabase stack. This configuration targets PostgreSQL 15.
3. Review the SQL files, then apply to the disposable local database with `supabase db reset`. **This command resets the local Supabase database and is destructive to its local data; do not run against a linked/production project.**
4. Run SQL acceptance tests with `supabase test db`. Run concurrency checks separately, only against the local URL from `supabase status -o env`, using `DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" bash supabase/tests/concurrent_sales.sh` and the same command ending in `concurrent_receipts.sh`. Confirm the target is local before running.
5. Generate TypeScript types from the local database after migrations with `supabase gen types typescript --local > lib/supabase/database.types.ts`; the current file is a hand-authored initial draft, not CLI-generated. Inspect and commit generated output before relying on it.
6. Run `npx tsc --noEmit`, `npm run lint`, and `npm run build`. ESLint is configured to ignore generated `.next`, `out`, and `build` outputs; the Tailwind plugin uses an ES module import.
7. Before any hosted use, compare the proposal against the actual target database, take a backup, apply to a staging branch, run RLS and regression tests, and obtain explicit review/approval. Do not run `supabase db push` against production automatically.

## Rollback

There is no automatic down migration because dropping populated ERP tables is destructive. For an empty disposable database only, remove and recreate the local stack/database. For any persistent environment, prepare a separately reviewed data-preserving rollback plan; do not drop business tables or discard financial/inventory history.
