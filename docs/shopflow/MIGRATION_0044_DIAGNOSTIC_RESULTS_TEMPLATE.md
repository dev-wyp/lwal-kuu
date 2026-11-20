# Migration 0044 Diagnostic Results Template

**Status:** No database diagnostic has been run or supplied for this review. All result fields below remain **NOT PROVIDED**. This document is a blank, sanitized capture template, not evidence about production or staging.

## Target and provenance

- Environment (local disposable / isolated staging / other): NOT PROVIDED
- Project name and ref, confirmed in operator console: NOT PROVIDED
- Query execution date/time and operator: NOT PROVIDED
- PostgreSQL version / Supabase CLI version (if applicable): NOT PROVIDED
- Migration history rows for `0043`–`0047`: NOT PROVIDED
- Diagnostic file revision / checksum: NOT PROVIDED
- Was the output reviewed against a backup or approved snapshot? NOT PROVIDED

Do not include credentials, JWTs, connection strings, customer/supplier names, emails, payment references, or raw row identifiers. Provide catalog definitions and aggregate counts only. A project ref is not a secret, but confirm it belongs to the intended non-production target before sharing results.

## Catalog results

| Query section | Sanitized result / attachment reference | Status | Reviewer notes |
| --- | --- | --- | --- |
| Relation existence, owner, RLS enabled/forced | NOT PROVIDED | BLOCKED |  |
| Exact allocation columns, PostgreSQL types, nullability, defaults | NOT PROVIDED | BLOCKED |  |
| Allocation PK / unique / FK / check / exclusion constraints | NOT PROVIDED | BLOCKED |  |
| Referenced FK tables and columns | NOT PROVIDED | BLOCKED |  |
| Allocation indexes and validity/readiness | NOT PROVIDED | BLOCKED |  |
| Parent unique keys/indexes on `supplier_payments` and `purchases` | NOT PROVIDED | BLOCKED | Need valid uniqueness for `(organization_id,id)` before composite FK creation. |
| RLS policies | NOT PROVIDED | BLOCKED | Include command, roles, `USING`, and `WITH CHECK` expressions. |
| Effective table grants for `PUBLIC`, `anon`, `authenticated`, `service_role` | NOT PROVIDED | BLOCKED | Include SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER. |
| Owned sequence names and effective sequence grants | NOT PROVIDED | BLOCKED | Include USAGE/SELECT/UPDATE; state explicitly if no sequence exists. |
| Non-internal triggers and trigger-function security metadata | NOT PROVIDED | BLOCKED | Include enabled state, function owner, SECURITY DEFINER, settings/search path. |
| Supplier-payment RPC signatures, definitions, owners, settings and ACLs | NOT PROVIDED | BLOCKED | Redact any embedded secret-like values if found. |

## Aggregate data results

Enter counts only. Preserve the SQL query version used and do not send row samples or identifiers.

| Aggregate | Count | Status / notes |
| --- | ---: | --- |
| Allocation rows | NOT PROVIDED | BLOCKED |
| Missing payment references | NOT PROVIDED | BLOCKED |
| Missing purchase references | NOT PROVIDED | BLOCKED |
| Missing tenant references | NOT PROVIDED | BLOCKED |
| Null, invalid, zero, or negative allocation amounts | NOT PROVIDED | BLOCKED |
| Orphan payment references | NOT PROVIDED | BLOCKED |
| Orphan purchase references | NOT PROVIDED | BLOCKED |
| Allocation tenant differs from payment tenant | NOT PROVIDED | BLOCKED |
| Allocation tenant differs from purchase tenant | NOT PROVIDED | BLOCKED |
| Payment and purchase belong to different tenants | NOT PROVIDED | BLOCKED |
| Payment and purchase supplier mismatch | NOT PROVIDED | BLOCKED |
| Duplicate payment/purchase pairs | NOT PROVIDED | BLOCKED |
| Payments whose allocations exceed payment amount | NOT PROVIDED | BLOCKED |
| Purchases whose allocations exceed purchase total | NOT PROVIDED | BLOCKED |

The diagnostic's candidate alias matching is exploratory only. A similar column name does not prove business meaning. Before interpreting any aggregate, record the exact source columns and have the application/schema owner confirm their semantics. If the existing aggregate query cannot safely express the verified schema, revise the read-only diagnostic for that schema before execution; do not cast or map unverified references.

## Compatibility decision

- Are payment and purchase reference columns identified by verified FK or documented application semantics? NOT PROVIDED
- Are their types compatible with the intended parent keys? NOT PROVIDED
- Can tenant ownership be proven from both referenced records? NOT PROVIDED
- Are all required parent composite unique keys valid and ready? NOT PROVIDED
- Are historical mismatches zero or covered by an approved remediation plan? NOT PROVIDED
- Is the existing table safe to extend without changing/dropping legacy columns or rows? NOT PROVIDED
- Decision: **BLOCKED — no schema mapping or corrected migration is approved by this evidence template.**

## Operator handoff checklist

1. Confirm a disposable local or isolated staging target and capture its project ref from the operator console. Production is forbidden for this investigation, including read-only queries, tests, or migration rehearsal.
2. Run the read-only statements in `docs/audit/supplier-payment-allocation-read-only-diagnostic.sql` one section at a time. The file does not select customer/supplier PII or return allocation row IDs.
3. Save the raw catalog output in the approved secure review location; copy only sanitized definitions and aggregate counts into this template.
4. Include the parent-key results and the exact function/RLS/grant/trigger output; a migration-history listing alone does not prove effective schema state.
5. Return the completed template for review. Do not retry/apply migration 0044 until an evidence-based compatibility proposal has been reviewed and local disposable migration tests pass.

