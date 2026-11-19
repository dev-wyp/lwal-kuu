# Production security query results

**Project name:** wholesale-erp  
**Expected project ref:** lfajonwbfweflkymuvmx  
**Observed project ref (Dashboard):** _operator to complete_  
**Run date/time and timezone:** _operator to complete_  
**Executing database role:** _operator to complete_  
**Operator / ticket reference:** _operator to complete_  
**Query pack version/hash:** _operator to complete_  
**Overall status:** NOT REVIEWED / BLOCKED / FINDINGS / VERIFIED WITH LIMITS  

> Use only sanitized result details. The platform-admin query can return email addresses; store those results only in an approved restricted location. Never record credentials, access tokens, database passwords, or service-role keys here. No result is pre-populated: this template does not assert any production finding is confirmed or fixed.

## Target and execution context

| Check | Result | Status (PASS / FAIL / BLOCKED / NOT REVIEWED) | Evidence / limitation |
| --- | --- | --- | --- |
| Dashboard project ref equals `lfajonwbfweflkymuvmx` |  |  |  |
| Database name and current/session roles from section 0 |  |  |  |
| Query execution was read-only and statements ran individually |  |  |  |

## 1. Platform administrators

Keep the detailed ID/email output in the restricted incident/evidence store. Record an allowlist comparison here using sanitized identifiers or a secure evidence reference.

| Check | Result | Status | Evidence / limitation |
| --- | --- | --- | --- |
| Admin row count |  |  |  |
| Number of rows reconciles to count |  |  |  |
| Approved allowlist reference/version |  |  |  |
| Unallowlisted account IDs found |  |  |  |
| `auth.users` email/account creation metadata accessible |  |  |  |
| Unrecognized admins escalated as potential incident |  |  |  |

## 2. Organization settings

| Query | Result summary | Status | Evidence / limitation |
| --- | --- | --- | --- |
| RLS enabled / forced / owner |  |  |  |
| All effective policy rows reviewed |  |  |  |
| Permissive SELECT and ALL policies reviewed |  |  |  |
| Any policy permits broad authenticated access |  |  |  |
| `anon` table privileges |  |  |  |
| `authenticated` table privileges |  |  |  |
| `service_role` table privileges |  |  |  |
| Helper functions, owner/bypass paths, and views reviewed |  |  |  |

## 3. Cron function privileges and scheduled jobs

| Function name and signature | Found / SECURITY DEFINER / owner | PUBLIC execute | anon execute | authenticated execute | service_role execute | Scheduled job and owner | Status / evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `cron_check_expired_subscriptions()` |  |  |  |  |  |  |  |
| `cron_queue_daily_sales_summaries()` |  |  |  |  |  |  |  |
| `cron_queue_low_stock_alerts()` |  |  |  |  |  |  |  |
| `cron_queue_subscription_renewal_reminders()` |  |  |  |  |  |  |  |
| `cron_queue_weekly_business_summary()` |  |  |  |  |  |  |  |
| `cron_run_all_automations()` |  |  |  |  |  |  |  |
| `cron_detect_expired_social_connections()` |  |  |  |  |  |  |  |
| `cron_notify_upcoming_scheduled_posts()` |  |  |  |  |  |  |  |
| `cron_queue_debt_reminders()` |  |  |  |  |  |  |  |
| `claim_due_publishing_jobs(integer,text)` |  |  |  |  |  |  |  |
| `complete_publishing_job(uuid,boolean,text,text,boolean)` |  |  |  |  |  |  |  |

**External scheduler / Edge Function paths reviewed:** _operator to complete_  
**`cron.job` absent or inaccessible:** _yes / no; evidence:_  
**Unrecognized active jobs or owners:** _operator to complete_

## 4. Cross-tenant foreign keys and mismatch counts

Record aggregate counts only. Do not attach customer names, email, phone, addresses, or transaction-level personal data.

### Foreign-key definitions

| Relationship group | Composite tenant FK coverage | Unvalidated/missing/ID-only constraints | Status / evidence |
| --- | --- | --- | --- |
| Products, categories, units, expenses |  |  |  |
| Purchases, items, suppliers, supplier payments |  |  |  |
| Sales, items, customers, branches |  |  |  |
| Payments and allocations |  |  |  |
| Stock adjustments, movements, transfers, branches |  |  |  |
| Polymorphic stock movement references | N/A: no ordinary FK |  |  |

### Aggregate mismatch counts

| Relationship | Mismatch count | Status (PASS only if zero and query completed) | Evidence / limitation |
| --- | ---: | --- | --- |
| Purchases and supplier relationships (4A) |  |  |  |
| Sales and customer/payment relationships (4B) |  |  |  |
| Stock and branch relationships (4C) |  |  |  |
| Category/unit relationships (4D) |  |  |  |
| Polymorphic movement references / unrecognized types (4E) |  |  |  |

### Existing supplier allocation relation shape (4F)

| Relation exists | Column names/types | Constraints and indexes | RLS/policies | Migration compatibility status |
| --- | --- | --- | --- | --- |
|  |  |  |  |  |

**Schema preflight completed:** _yes / no_  
**Missing objects/columns or blocked query sections:** _exact sanitized error and section_  
**RPC ownership and allocation checks separately verified:** _yes / no / blocked; evidence:_

## 5. Migration history

Local expected migration files: **44 (`0001`–`0044`)**. Operator logs report `0043_p0_transaction_integrity.sql` applied and `0044_supplier_payment_workflow.sql` failed; confirm this against the remote migration history and do not infer success from the CLI output alone.

| Check | Result | Status | Evidence / limitation |
| --- | --- | --- | --- |
| `supabase_migrations.schema_migrations` exists and is visible |  |  |  |
| Remote version/name rows captured |  |  |  |
| Remote rows manually compared with local `0001`–`0042` filenames |  |  |  |
| Missing/unexpected versions |  |  |  |
| Duplicate/out-of-order versions or other discrepancy |  |  |  |
| Catalog state separately checked against migration claims |  |  |  |

**If blocked, exact reason:** _operator to complete_  
**Evidence reference (do not paste credentials):** _operator to complete_

## Findings and disposition

For each issue, use the finding format below. A query result is evidence of current catalog/data state only within its stated scope. Do not say “fixed” without a later verified production result.

### Finding _ID_

- **Severity:**
- **Status:** Confirmed / Potential / Not reproduced / Blocked
- **Evidence and query section:**
- **Affected tables/functions:**
- **Business impact:**
- **Recommended correction:**
- **Verification procedure / owner:**
- **Evidence reference:**

## Final review

| Decision item | Result |
| --- | --- |
| All requested queries completed or explicitly marked blocked |  |
| Admin IDs compared to approved allowlist |  |
| No customer personal information included in this report |  |
| Every nonzero mismatch and unexpected privilege escalated |  |
| Production remains labeled unverified where evidence is unavailable |  |
| Reviewer and review date |  |

