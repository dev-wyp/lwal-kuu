-- SQL assertions for marketing approval isolation.
-- Run against a disposable local database after applying migrations 0021-0023.

do $$
begin
  if to_regprocedure('public.approve_marketing_content(uuid)') is null then
    raise exception 'approve_marketing_content RPC is missing';
  end if;
  if to_regprocedure('public.enqueue_marketing_publish(uuid)') is null then
    raise exception 'enqueue_marketing_publish RPC is missing';
  end if;
end $$;

select 'marketing rpcs exist' as test;
