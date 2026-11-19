# Production Readiness Checklist

**Current decision:** NOT READY / UNVERIFIED. This checklist distinguishes local implementation from effective production state.

## Database and tenant safety (P0)

- [ ] Approved project ref `lfajonwbfweflkymuvmx` confirmed in operator session.
- [ ] Production migration history reconciled with migrations `0001`–`0044`.
- [ ] Active schema/functions/policies/grants compared with migration source.
- [ ] `profiles.is_platform_admin` IDs reconciled with approved allowlist; unexpected accounts escalated.
- [ ] `organization_settings` policies and grants verified; two-organization SELECT test passes.
- [ ] Existing cross-tenant mismatches measured and remediated under an approved plan.
- [ ] Composite tenant FK migration replayed and constraints validated after data review.
- [ ] Every SECURITY DEFINER RPC has reviewed owner, fixed search path, body authorization, and role ACL.
- [ ] Global cron functions callable only by approved scheduler/service paths; actual job owners verified.
- [ ] Two-tenant RLS tests cover reads and writes, views, RPCs and platform admin.
- [ ] Production backups and restore capability independently verified.

## Transaction integrity (P0)

- [ ] Sale recomputation, branch stock, duplicate retry, payment and movement writes pass SQL/concurrency tests.
- [ ] Customer payment identity, allocation ceilings, advance and reversal behavior pass tests.
- [ ] Purchase receipt/product costs, supplier payment, partial GRN and duplicate handling pass tests.
- [ ] Cross-tenant references are rejected across sales/purchases/payments/stock/transfers.
- [ ] Returns/refunds/credits use auditable compensating transactions.
- [ ] Posted records cannot be deleted or overwritten through restore/import paths.

## Core operations and financial trust (P1)

- [ ] Products, stock, purchasing/receiving, POS, payments and corrections complete in a single traceable workflow.
- [ ] Cash/bank/wallet account ledger and transfers reconcile; transfers are not income/expense.
- [ ] Double-entry journals balance and reverse correctly; closed periods reject posts.
- [ ] Sales, stock, AR/AP, profit and cash reports reconcile to source ledgers and disclose cash/accrual basis.
- [ ] Asia/Yangon period boundaries and branch filtering verified.
- [ ] Physical count, damage, write-off and branch reconciliation use stock movements.

## SaaS operations (P1/P2)

- [ ] Trial, renewal, manual payment review, upgrade/downgrade and entitlements tested at RPC level.
- [ ] Notification outbox retries, deduplicates, exposes failed jobs and does not need routine admin dispatch.
- [ ] Support ticket tenant isolation and priority-support entitlements verified.
- [ ] Backup tenant export is clearly distinguished from provider full backup/DR.

## Application quality

- [ ] Generated DB types match validated staging schema and all RPC signatures.
- [ ] Strict build and lint pass.
- [ ] Unit, SQL integration, two-tenant, concurrency and Playwright workflows pass in dedicated test environments.
- [ ] Mobile/tablet/desktop routes and core transactional forms have no layout/keyboard defects.
- [ ] Loading, validation, empty, failure, retry and success states are understandable to nontechnical shop staff.

## Deployment and operations

- [ ] Backup before migration and successful staging restore drill.
- [ ] Staging clean replay and upgrade path pass; migration duration and locks reviewed.
- [ ] Roll-forward/rollback and data remediation plan documented per migration.
- [ ] Secrets remain server-side and rotation/contact ownership documented without embedding secret values.
- [ ] Monitoring covers RPC failures, job queues, notification failures, ledger mismatches and auth anomalies.
- [ ] Incident owner and escalation process documented.
- [ ] Production migration/application release receives explicit change approval after evidence review.

## Evidence record

| Gate | Evidence reference | Owner | Date | Status |
| --- | --- | --- | --- | --- |
| Production project/migration ledger |  |  |  | BLOCKED |
| Admin allowlist review |  |  |  | BLOCKED |
| RLS/grants/two-tenant tests |  |  |  | NOT VERIFIED |
| P0 transaction tests |  |  |  | NOT RUN |
| Backup/restore drill |  |  |  | NOT VERIFIED |
| Release approval |  |  |  | NOT APPROVED |

