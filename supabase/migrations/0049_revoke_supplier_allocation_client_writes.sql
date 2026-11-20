-- Restore the intended RPC-only write boundary for supplier allocations.
-- Keep authenticated reads subject to the existing tenant RLS policy and
-- preserve service_role access for trusted server operations.
begin;

revoke all privileges on table public.supplier_payment_allocations
  from public, anon, authenticated;
grant select on table public.supplier_payment_allocations
  to authenticated, service_role;

commit;
