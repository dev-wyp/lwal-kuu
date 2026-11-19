# Global cron function privilege review

**Status:** Function source was enumerated. Effective EXECUTE privileges in production could not be inspected. All SQL below is a proposal only and has not been executed.

## Functions and source-level risk

| Function | Source behavior | Source grant evidence | Assessment |
| --- | --- | --- | --- |
| `cron_check_expired_subscriptions()` | Changes trialing/active subscription states across organizations | No explicit source `REVOKE`/`GRANT` found in migrations | High risk if client EXECUTE remains; global state mutation |
| `cron_queue_daily_sales_summaries()` | Scans all organizations and queues owner emails/sales totals | No explicit source `REVOKE`/`GRANT` found | High risk if client EXECUTE remains; cross-tenant job side effect |
| `cron_queue_low_stock_alerts()` | Scans tenant stock and queues owner notifications | No explicit source `REVOKE`/`GRANT` found | High risk if client EXECUTE remains |
| `cron_queue_subscription_renewal_reminders()` | Scans subscriptions and queues renewal reminders | No explicit source `REVOKE`/`GRANT` found | High risk if client EXECUTE remains |
| `cron_queue_weekly_business_summary()` | Scans tenant sales and queues weekly summaries | No explicit source `REVOKE`/`GRANT` found | High risk if client EXECUTE remains |
| `cron_run_all_automations()` | Calls several global jobs; body requires `is_platform_admin()` | No explicit source `REVOKE`/`GRANT` found; called by platform admin UI | Body guard is useful, but public execution should still be removed |
| `cron_detect_expired_social_connections()` | Updates social account connection state across workspaces and queues notifications | No explicit source `REVOKE`/`GRANT` found; edge function calls it with service client | High risk if client EXECUTE remains |
| `cron_notify_upcoming_scheduled_posts()` | Scans scheduled content and inserts notifications | No explicit source `REVOKE`/`GRANT` found; edge function calls it with service client | High risk if client EXECUTE remains |
| `cron_queue_debt_reminders()` | Scans overdue sales and queues customer debt email reminders | Migrations revoke from PUBLIC/anon and grant authenticated/service_role; body rejects authenticated non-platform-admin callers | Source is more restricted, but effective grants and runtime guard are not verified |

Related background worker functions `claim_due_publishing_jobs(integer,text)` and `complete_publishing_job(uuid,boolean,text,text,boolean)` are explicitly revoked from PUBLIC/anon/authenticated and granted to `service_role` in migration `0022`/`0024`. Confirm those grants in the live catalog too.

### Findings

#### C-01 — Scheduled SECURITY DEFINER jobs lack consistent explicit client revocation

- **Severity:** Critical pending live ACL verification
- **Affected functions:** The first eight rows above; `notification_outbox`, `subscriptions`, `social_accounts`, `marketing_notifications`, sales/report source tables.
- **Evidence:** Each function is `SECURITY DEFINER` with fixed `search_path`; most job definitions contain no caller-role check and no matching source-level revoke/grant. PostgreSQL commonly grants EXECUTE on new functions to `PUBLIC` unless default privileges are changed. The effective grants cannot be established from migration source alone.
- **Business impact:** If client roles can invoke them, unauthenticated or ordinary users could cause global subscription state transitions, cross-tenant notification queue writes, or social-account state changes.
- **Recommended correction:** Explicitly revoke client execution from global jobs and grant only to the approved worker/service role. Keep `cron_run_all_automations` reachable by authenticated users only if its platform-admin guard is retained and covered by tests.
- **Verification procedure:** In production, inspect `pg_proc.proacl`/`aclexplode` for all function signatures and evaluate `has_function_privilege` for `anon`, `authenticated`, and `service_role`. In staging, attempt calls as anon, ordinary tenant user, platform admin, and service role.

## Proposed grants/revokes — not applied

The proposal for global worker functions is:

```sql
revoke execute on function public.cron_check_expired_subscriptions()
  from public, anon, authenticated;
revoke execute on function public.cron_queue_daily_sales_summaries()
  from public, anon, authenticated;
revoke execute on function public.cron_queue_low_stock_alerts()
  from public, anon, authenticated;
revoke execute on function public.cron_queue_subscription_renewal_reminders()
  from public, anon, authenticated;
revoke execute on function public.cron_queue_weekly_business_summary()
  from public, anon, authenticated;
revoke execute on function public.cron_detect_expired_social_connections()
  from public, anon, authenticated;
revoke execute on function public.cron_notify_upcoming_scheduled_posts()
  from public, anon, authenticated;

grant execute on function public.cron_check_expired_subscriptions()
  to service_role;
grant execute on function public.cron_queue_daily_sales_summaries()
  to service_role;
grant execute on function public.cron_queue_low_stock_alerts()
  to service_role;
grant execute on function public.cron_queue_subscription_renewal_reminders()
  to service_role;
grant execute on function public.cron_queue_weekly_business_summary()
  to service_role;
grant execute on function public.cron_detect_expired_social_connections()
  to service_role;
grant execute on function public.cron_notify_upcoming_scheduled_posts()
  to service_role;
```

The application invokes `cron_run_all_automations()` from the platform admin page; its function body checks `is_platform_admin()`. If retaining this UI path, use:

```sql
revoke execute on function public.cron_run_all_automations()
  from public, anon;
grant execute on function public.cron_run_all_automations()
  to authenticated, service_role;
```

`cron_queue_debt_reminders()` is also invoked directly from that page and already has an in-function platform-admin check for authenticated callers. The source proposal is to retain only the guarded authenticated UI and service-role paths:

```sql
revoke execute on function public.cron_queue_debt_reminders()
  from public, anon;
grant execute on function public.cron_queue_debt_reminders()
  to authenticated, service_role;
```

The scheduled `pg_cron` job must run under a role that owns or is explicitly allowed to invoke these functions. Confirm the actual job owner/role before choosing grants; do not assume `service_role` is the `pg_cron` execution role.

## Verification blocked

The linked production target is correct, but Supabase CLI access is unavailable. Therefore this review cannot state which functions are currently executable by PUBLIC, anon, authenticated, or service_role. No revocation or grant was applied.
