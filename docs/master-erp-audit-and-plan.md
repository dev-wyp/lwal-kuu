# Myanmar Wholesale ERP — Master Audit & Implementation Plan

**Audit date:** 2026-10-16  
**Status:** Initial audit findings remain applicable to the original checkout. Follow-up work has created review-only proposed Phase 1 migrations and a working first application slice; no live Supabase database was modified. The complete master requirements remain incomplete, and the supplied master prompt still ends during Products.

## Executive summary

The checked-out `wholesale-erp` repository is an early Next.js/Supabase starter with authentication pages, a single untracked sales page, and prior planning-only Phase 2/Phase 3 documents. It does not contain the database migrations, schema, generated database types, or tests needed to verify that the stated Phase 1 or Phase 2 ERP foundations exist. There is no complete, data-backed ERP implementation in this checkout.

The supplied master prompt available in this conversation ends partway through the Products section at “Product detail page”; the rest of its module requirements and acceptance criteria are not present. I can plan for the visible dashboard/products scope and the requirements already supplied in the Phase 2/3 prompts, but cannot responsibly claim the complete master requirements are known.

## Files and areas inspected

- Project structure and hidden/local project files, excluding dependency/build internals; Git tracked files, working-tree state, all available branches/history.
- [package.json](../package.json), [README.md](../README.md), [.env.example](../.env.example), [next.config.ts](../next.config.ts), [tsconfig.json](../tsconfig.json), [tailwind.config.ts](../tailwind.config.ts), and [globals.css](../app/globals.css).
- App routes: `app/page.tsx`, `app/protected/page.tsx`, `app/protected/layout.tsx`, `app/sales/page.tsx`, and auth routes/forms.
- Supabase integration: `lib/supabase/client.ts`, `lib/supabase/server.ts`, `lib/supabase/proxy.ts`, and root `proxy.ts`.
- Existing reusable UI under `components/ui/`, authentication components, the schema-independent supplier form, and Phase 2/3 planning documents.
- Workspace-wide searches for SQL migrations, Supabase migration folders, Prisma schemas, database TypeScript types, and schema/RPC references. Other applications' migrations were found but are unrelated and were not reused. Environment values/secrets were not read into this report.

## Verified current state

### Application and configuration

- Next.js App Router, React, strict TypeScript, Tailwind, Supabase SSR/Auth clients, and basic auth forms are present.
- The only configured scripts are `dev`, `build`, `start`, and `lint`; no test or DB migration/type-generation script exists.
- `app/sales/page.tsx` is present but untracked in Git. It queries `memberships(user_id, org_id)`, `organizations(id, name)`, and `stock_balances(product_id, org_id, sku, name, unit, sale_price, stock_on_hand)`; it submits a transaction through `create_sale` with org, items, optional customer, and payment-method parameters. These are client assumptions, not verified DB definitions.
- The starter protected layout and dashboard placeholder show auth claims/tutorial material, not ERP metrics. The root proxy refreshes/checks claims, but database membership/role/RLS enforcement is not verifiable from app code.
- An isolated supplier form and Phase 2/3 design documents are untracked or planning-only; no supplier, purchase, receiving, supplier-payment, customer-receivables, or reporting modules are connected to a database.
- Workspace app routes do not yet implement the visible requested `/dashboard` or `/products` modules. The prompt itself only partially specifies products.

### Database/security gaps

No SQL migrations or schema files, `supabase/migrations`, Prisma schema, generated Supabase `Database` types, SQL function/RPC definitions, RLS policy definitions, database tests, or schema dump are present in `wholesale-erp` or its available Git history. No Supabase CLI/database-inspection connection is configured in the workspace; only public client configuration is present. Thus the following are not verified:

- organizations, memberships, customers, products, sales invoices/items, stock movements/balances, supplier/purchase/receipt/payment tables;
- payment/ledger/journal/returns structures or business number generators;
- foreign keys, organization-aware composite constraints, numeric precision, statuses, triggers, grants, RLS policies, or role permissions;
- the body, owner, `search_path`, grants, transaction semantics, and membership checks of `create_sale` or any inventory RPC.

Using a public key to probe the database schema is not valid access; the earlier REST OpenAPI probe returned HTTP 401. No production data was read or changed.

## Risks and decisions

1. **Schema mismatch / duplicate accounting:** Phase 2/3 implementations written against invented invoice/payment tables can duplicate financial records or bypass existing stock/sales transactions.
2. **Tenant isolation:** client-side `org_id` filtering is not authorization. The actual membership helper, roles, policies, and FK structure must be inspected before connecting new business routes.
3. **Credit/payment correctness:** sales invoice/collection semantics, due dates, returns/credit notes, and accounting journals are unknown.
4. **Incomplete master requirements:** the available prompt cuts off in the Products section. Full module list and acceptance criteria are needed to complete the master request faithfully.
5. **Untracked baseline files:** the sales route, supplier form, and phase planning documents are currently untracked in Git; preserve/review them before committing or broad rewrites.

## Proposed additive sequence

1. **Reconcile source of truth:** obtain a sanitized Phase 1/2 schema/migration dump plus function/RLS/grant definitions, or enable a read-only authenticated DB-inspection connection. Generate database types from the verified schema. Also provide the remainder of the master prompt.
2. **Baseline/security:** test auth/session and organization membership behavior with two organizations and distinct users; document actual role permissions. Protect routes and data access using existing authenticated server/client and PostgreSQL RLS.
3. **Foundation UI:** implement responsive signed-in app shell, dynamic organization selection from verified memberships, account/profile/settings, and data-backed dashboard. Every metric must derive from verified queries/RPCs; use honest empty/loading states.
4. **Master data:** products and customers (and suppliers if Phase 2 is not already available), with database-backed search/filter/pagination and authorized writes.
5. **Inventory and sales:** reuse existing stock movement and sale posting transaction; add purchase/receiving and AR only after reconciling the documented Phase 2/3 policies with real tables and finance integration.
6. **Finance and reports:** implement payment allocation, immutable reversals, ledger reconciliation, credit controls, and date/timezone-aware reports through trusted transactional database functions.
7. **Verification and rollout:** add disposable-DB RLS, idempotency, concurrency, rollback, accounting reconciliation, and Phase 1 regression tests; apply additive migrations to staging first, then production only after review/backup/approval.

Previously confirmed business policies to preserve: purchase orders do not increase stock; accepted goods do; GRNI is recognized for goods received before supplier invoice and reclassified when invoiced; receivables and payables derive from valid source transactions/allocations, not manually editable balances.

## Work completed for this master request

- The initial audit and implementation plan are recorded here; the prior Phase 2/3 audit plans are retained as historical planning artifacts.
- Follow-up created a **proposed, unapplied** Phase 1 schema and secure product/inventory/sales/purchasing RPCs under `supabase/migrations/`, SQL and two-session concurrency tests, local setup notes, and a hand-authored initial TypeScript contract. See [Supabase setup notes](../supabase/README.md).
- Implemented `/dashboard`, `/products`, `/products/[id]`, `/inventory`, `/sales`, `/suppliers`, `/purchases`, `/purchases/[id]`, and `/supplier-payments`, reusing and typing the existing Supabase clients.
- The supplier flow supports create/edit/deactivate. Purchase orders are idempotent and do not affect stock; partial receipt posting locks purchase/items and updates stock/GRNI transactionally; supplier invoices reclassify GRNI to actual invoice payable and record price variance; supplier payments support invoice allocations and unallocated advances.
- All four migrations, both SQL acceptance suites, and concurrent sale/receipt scripts passed against fresh temporary PostgreSQL 14 databases with a minimal Auth-compatible schema. This is not a Supabase CLI/Auth integration test or proof of compatibility with the unknown hosted database.
- No production Supabase migration was applied and no destructive change was performed.
- Still not implemented: balanced cash/bank/general journal posting, supplier advance application and payment reversals, goods receipt reversals, customer payment allocations/receivables UI, expenses, reports, organization invitations/role management, and full accounting reconciliation. The supplier subledger is not a double-entry cash/bank journal.
- The Supabase CLI is unavailable and Docker's daemon is not running, so Supabase local-stack tests were not run.

## Validation state

Follow-up validation: `npx tsc --noEmit`, full `npm run lint`, and `npm run build` passed. Both SQL acceptance suites and the concurrent sales/receipt shell tests passed against the temporary PostgreSQL harness. Supabase CLI/Auth tests and production-database tests were not run. No npm test script exists.

## Unblock checklist

- [ ] Review the proposed Phase 1 schema against a sanitized dump of the actual ERP database, including relevant table definitions, constraints, RLS policies, grants, and SQL RPC/function definitions (especially sales and stock operations), or explicitly choose to use the design only for a new local/staging Supabase project.
- [ ] Provide the complete master prompt after “Product detail page”.
- [ ] Confirm which Phase 2/3 features are already live in Supabase versus merely planned in this checkout, so the implementation avoids duplicate tables and financial postings.
- [ ] Then review the proposed mapping and add only schema-reconciled, additive migrations; never apply draft SQL directly to production.
