-- Rename user-facing ShopFlow branding while preserving internal identifiers.
alter table public.marketing_workspaces
  alter column brand_name set default 'Lwal Kuu';

update public.marketing_workspaces
set brand_name = 'Lwal Kuu'
where brand_name = 'ShopFlow';

update public.notification_outbox
set subject = replace(subject, 'ShopFlow:', 'Lwal Kuu:')
where subject like 'ShopFlow:%';

-- Update existing automation function bodies so future email subjects use the new brand.
do $$
declare
  fn record;
  fn_definition text;
begin
  for fn in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc like '%ShopFlow%'
  loop
    fn_definition := pg_get_functiondef(fn.oid);
    execute replace(fn_definition, 'ShopFlow', 'Lwal Kuu');
  end loop;
end;
$$;
