# P0 release-readiness checklist

**Audit date:** 2026-11-18  
**Decision:** **NOT READY** for pilot or production transactions.

This is a source audit plus frontend test run. Production migration history, effective RLS/grants, business records, staging migrations, and backup recovery were not inspected or changed. No production migration was applied. The audit reports are read-only deliverables; implementation must wait for explicit approval.

## Release gates

| Gate | Status | Evidence and required action |
| --- | --- | --- |
| One verified database contract | **Blocked** | The 42-file migration chain and generated snapshot match, but live production history/schema could not be read because the CLI has no access token. Compare a read-only catalog/history export before staging. |
| Platform-admin allowlist | **Critical open item** | Migration `0015` grants admin to all users existing at its application time. Read the production allowlist immediately and compare to authorized operators. |
| Two-tenant row isolation | **Fail by source finding / runtime unverified** | `organization_settings` SELECT includes a blanket authenticated policy. Correct it, then run a complete two-tenant policy/RPC suite on disposable staging. |
| Tenant-consistent foreign references | **Fail by source finding** | Core transaction FKs are not organization-composite; privileged receive/confirm routines join by IDs. Add constraints/validation and prove cross-tenant references reject atomically. |
| RPC execution privileges | **Unverified / high risk** | Several global cron `SECURITY DEFINER` routines lack explicit client execution revocation. Query effective grants and lock them to the scheduler/service role. |
| Purchase-to-pay transaction workflow | **Fail by missing workflow** | Active schema supports only one full receipt per PO; no receipt-level partial delivery, GRNI, supplier invoice, or supplier allocation workflow. |
| Sale/payment correctness | **Fail by source finding** | Confirmation trusts client-entered totals; payment allocation caps/customer relationship are not enforced; sale reversal omits payment reversal. |
| Financial reconciliation | **Not verified** | No independently calculated report reconciliation tests; cash/bank methods are not separated; business dates do not explicitly use Asia/Yangon in core paths. |
| Migration compatibility | **Blocked** | Production migration list unavailable; local replay unavailable because Docker/PostgreSQL are unavailable. Do not use production as a test target. |
| Backup and recovery | **Not verified** | Documentation describes a sequence but no backup artifact or restore drill was observed. Restore RPC can upsert posted ledger rows and needs review before reliance. |
| Frontend static/unit/E2E checks | **Passed** | `tsc`, lint, build, unit suite, and 5/5 current E2E scenarios passed. These do not clear database/business workflow gates. |

## Recommended implementation and verification order

1. **Contain and verify current tenant exposure.** Read-only inspect platform-admin assignments, organization-settings access, and effective cron function grants on production. Do not update production during this audit; prepare a reviewed containment migration after approval.
2. **Close cross-tenant write paths.** Add organization-aware foreign keys and server validation for customer, supplier, product, sale, purchase, branch, and allocation relationships. Scope idempotency lookups by tenant.
3. **Make transaction RPCs authoritative.** Move sale and purchase creation/line validation to atomic server-side routines; calculate prices/totals on the server; validate cash/credit/tender amounts; implement allocation caps, idempotent retries, partial receipts, supplier invoice/payable allocation, and append-only corrections/reversals.
4. **Define financial ledgers and report formulas.** Separate cash/bank tender accounts, customer unapplied advances, supplier advances/payables, and recognized liabilities. Define Asia/Yangon business date assignment.
5. **Build disposable database suites.** Test all policies/roles with two tenants; add concurrent receiving/sale/payment cases and source-to-report reconciliation fixtures. Run against clean replay and upgrade paths.
6. **Verify backup/recovery and staging history.** Take a verified backup, restore it into an isolated staging project, compare database history/schema, apply reviewed migrations to staging, run the full suite, and perform live Supabase UAT before considering a production release.

## Decision rationale

The app has useful ERP screens and several transactional RPCs, but static source shows cross-tenant authorization risks, untrusted financial inputs, missing partial receiving/payable workflows, incomplete reversals, and no executed database verification. These conditions can produce data exposure or incorrect stock and balances. Classify as **NOT READY** until the critical gates above pass in staging and authorized live UAT.
