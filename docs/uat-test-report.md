# ShopFlow UAT Test Report

**Project:** ShopFlow — Wholesale & Small Shop Management SaaS  
**Version:** 1.0.0-MVP  
**Report Date:** 2026-11-10  
**Environment:** Local Development (Vite + React + MUI + Supabase)  
**Status:** ✅ ALL AUTOMATED TESTS PASSING

---

## Executive Summary

| Test Suite | Tests | Passed | Failed | Status |
|---|---|---|---|---|
| TypeScript Compilation | — | ✅ 0 errors | — | PASS |
| ESLint Lint | — | ✅ 0 warnings | — | PASS |
| Business Logic Unit Tests | 11 | 11 | 0 | ✅ PASS |
| Playwright E2E Tests | 3 | 3 | 0 | ✅ PASS |
| Production Build | — | ✅ 0 errors | — | PASS |

---

## 1. TypeScript & Build Verification

### 1.1 TypeScript Strict Mode (`npx tsc --noEmit`)
- **Result:** Exit code 0 — Zero type errors
- **Mode:** `"strict": true` in tsconfig.json

### 1.2 ESLint (`npm run lint`)
- **Result:** Exit code 0 — Zero errors, zero warnings
- **Config:** Flat ESLint config with react-hooks rules, TypeScript ESLint

### 1.3 Production Build (`npm run build`)
- **Result:** Exit code 0 — Build successful
- **Chunks produced (with code splitting):**

| Chunk | Size | Gzip |
|---|---|---|
| `vendor-mui` (MUI + Emotion) | 467.32 kB | 142.09 kB |
| `vendor-supabase` | 228.75 kB | 59.45 kB |
| `index` (App code) | 139.70 kB | 31.18 kB |
| `vendor-data` (TanStack/RHF/Zod) | 127.93 kB | 36.11 kB |
| `vendor-react` (React + Router) | 93.40 kB | 31.59 kB |

> **Note:** Monolithic 1,059 kB bundle is now split into 6 separate vendor chunks, eliminating the chunk size warning. Total gzip is 300 kB.

---

## 2. Business Logic Unit Tests

**Command:** `npm run test:unit` → `node tests/unit/business-logic.test.mjs`  
**All 11 assertions PASSED**

### 2.1 Weighted Average Cost (WAC) Calculations

| # | Test | Expected | Result |
|---|---|---|---|
| 1 | Initial purchase sets avg cost | 80,000 MMK | ✅ PASS |
| 2 | Second equal-qty purchase updates avg | 85,000 MMK | ✅ PASS |
| 3 | Unequal qty purchase updates avg | 94,000 MMK | ✅ PASS |

**Rule:** `new_avg = (existing_qty × old_avg + new_qty × new_cost) / (existing_qty + new_qty)`

### 2.2 Gross Profit Calculations

| # | Test | Expected | Result |
|---|---|---|---|
| 4 | Revenue calculation | 380,000 MMK | ✅ PASS |
| 5 | COGS calculation (WAC) | 340,000 MMK | ✅ PASS |
| 6 | Gross profit (Revenue − COGS) | 40,000 MMK | ✅ PASS |
| 7 | Gross margin % | 10.53% | ✅ PASS |

### 2.3 Payment Allocation Logic

| # | Test | Expected | Result |
|---|---|---|---|
| 8 | Payment allocated across 2 invoices | Yes | ✅ PASS |
| 9 | INV-001 fully paid | 150,000 MMK | ✅ PASS |
| 10 | INV-002 partially paid | 100,000 MMK | ✅ PASS |
| 11 | No unallocated remainder | 0 MMK | ✅ PASS |

---

## 3. Playwright E2E Tests

**Command:** `npx playwright test --reporter=list`  
**Browser:** Chromium (headless)  
**All 3 scenarios PASSED** (3.8s total)

### Scenario 1: Public Landing and Pricing Page Navigation ✅ PASS (1.8s)

**Steps:**
1. Navigate to `/` (landing page)
2. Assert `<h1>` contains "Manage Products, Sales & Credit Ledgers"
3. Click "View Plans & Pricing" CTA button
4. Assert URL matches `/pricing`
5. Assert "Starter Plan" heading is visible
6. Assert "Business Plan" heading is visible  
7. Assert "Pro Plan" heading is visible

**Fix applied:** Changed `locator('text=Business Plan')` to `getByRole('heading', { name: 'Business Plan' })` to avoid strict-mode violation.

### Scenario 2: Authentication and Form Validations ✅ PASS (1.9s)

**Steps:**
1. Navigate to `/login`
2. Assert "Sign In to ShopFlow" is visible
3. Click submit with empty form
4. Assert Zod validation message: "Please enter a valid email address"
5. Click "Start free trial" link
6. Assert URL matches `/register`
7. Assert "Create Your Account" heading is visible

### Scenario 3: Responsive POS Register and Pricing Toggle ✅ PASS (1.9s)

**Steps:**
1. Navigate to `/pricing`
2. Click "Monthly Billing" toggle
3. Assert monthly price "15,000" (MMK) is visible
4. Click "Yearly Billing" toggle
5. Assert yearly price "150,000" (MMK) is visible

---

## 4. UAT Scenario Matrix (Manual / Live System)

The following scenarios require a live Supabase database connection.

| # | Scenario | Module | Priority | Status |
|---|---|---|---|---|
| UAT-01 | User Registration & Email Verification | Auth | P0 | 🔲 Pending DB |
| UAT-02 | Organization Creation & Trial Activation | Onboarding | P0 | 🔲 Pending DB |
| UAT-03 | Tenant Isolation Verification | Security | P0 | 🔲 Pending DB |
| UAT-04 | Product & Category Management | Products | P1 | 🔲 Pending DB |
| UAT-05 | Supplier & Purchase Order Creation | Purchases | P1 | 🔲 Pending DB |
| UAT-06 | Receive Purchase & Stock Increase | Inventory | P0 | 🔲 Pending DB |
| UAT-07 | Customer Management | Customers | P1 | 🔲 Pending DB |
| UAT-08 | Cash Sale & Stock Decrease | Sales | P0 | 🔲 Pending DB |
| UAT-09 | Credit Sale | Sales | P0 | 🔲 Pending DB |
| UAT-10 | Partial Payment & Allocation | Payments | P0 | 🔲 Pending DB |
| UAT-11 | Customer Ledger & Outstanding Balance | Customers | P0 | 🔲 Pending DB |
| UAT-12 | Sale Void & Reversal | Sales | P1 | 🔲 Pending DB |
| UAT-13 | Subscription Plan Upgrade | Subscription | P1 | 🔲 Pending DB |
| UAT-14 | Plan Usage Limit Enforcement | Security | P0 | 🔲 Pending DB |
| UAT-15 | Report Generation (CSV Export) | Reports | P2 | 🔲 Pending DB |

### Pre-requisites for Live UAT
```bash
supabase login
supabase link --project-ref lfajonwbfweflkymuvmx
supabase db push
npm run dev
# Open http://localhost:3000
```

---

## 5. Security Verification Checklist

| Check | Mechanism | Verified |
|---|---|---|
| Cross-tenant data isolation | PostgreSQL RLS on all tables | 🔲 Pending DB |
| No service-role key in frontend | ENV vars checked | ✅ Confirmed |
| Organization membership check in RPCs | `SECURITY DEFINER` functions | ✅ Code review |
| Idempotency on financial mutations | `idempotency_key` columns | ✅ Code review |
| No hard-delete of confirmed records | RLS policies block DELETE | 🔲 Pending DB |
| Stock movements immutable | No UPDATE/DELETE RLS | ✅ Code review |

---

## 6. Performance Metrics

| Metric | Value | Threshold | Status |
|---|---|---|---|
| Production bundle (gzip) | 300 kB | < 500 kB | ✅ PASS |
| Largest chunk (MUI, gzip) | 142 kB | < 200 kB | ✅ PASS |
| TypeScript errors | 0 | 0 | ✅ PASS |
| ESLint warnings | 0 | 0 | ✅ PASS |
| E2E test duration | 3.8s | < 60s | ✅ PASS |

---

## 7. Known Issues & Deferred Items

| ID | Issue | Severity | Resolution |
|---|---|---|---|
| DEFERRED-01 | Supabase migrations not yet applied to live DB | High | Apply via `supabase db push` |
| DEFERRED-02 | Manual payment verification only (no gateway) | Medium | Planned post-MVP |
| DEFERRED-03 | No Sentry DSN configured | Low | Add `VITE_SENTRY_DSN` to `.env` |
| DEFERRED-04 | No PostHog key configured | Low | Add `VITE_POSTHOG_KEY` to `.env` |
| DEFERRED-05 | Resend email not tested end-to-end | Medium | Test after DB setup |

---

## 8. Sign-Off

| Role | Date | Status |
|---|---|---|
| Developer (Automated) | 2026-11-10 | ✅ All automated tests PASS |
| QA Lead | — | 🔲 Pending live UAT |
| Product Owner | — | 🔲 Pending live UAT |
