-- Harden the existing subscription flow without replacing its tables or data.
alter table public.subscriptions
  add column if not exists grace_period_ends_at timestamptz;

alter table public.subscriptions drop constraint if exists subscriptions_status_check;
alter table public.subscriptions add constraint subscriptions_status_check
  check (status in ('trialing', 'active', 'past_due', 'expired', 'canceled', 'suspended'));

alter table public.subscription_payments
  add column if not exists subscription_event_id uuid references public.subscription_events(id) on delete set null;
create unique index if not exists subscription_payments_event_unique
  on public.subscription_payments(subscription_event_id) where subscription_event_id is not null;

-- Existing pending payment events become pending payment records, preserving history.
insert into public.subscription_payments (
  subscription_id, organization_id, amount, currency, payment_method,
  transaction_reference, payment_status, notes, subscription_event_id, created_at
)
select e.subscription_id, e.organization_id, coalesce(e.amount, 0), 'MMK',
       e.payment_method, e.payment_reference, 'pending', e.admin_notes, e.id, e.created_at
from public.subscription_events e
where e.event_type = 'payment_submitted'
on conflict (subscription_event_id) where subscription_event_id is not null do nothing;

create or replace function public._resolve_subscription_status(p_org_id uuid, out v_status text, out v_plan_id text)
returns record language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype;
begin
  v_status := 'none'; v_plan_id := null;
  select * into s from public.subscriptions where organization_id = p_org_id;
  if not found then return; end if;
  v_plan_id := s.plan_id;
  case s.status
    when 'trialing' then v_status := case when s.trial_ends_at > now() then 'trialing' else 'expired' end;
    when 'active' then
      if s.current_period_end > now() then v_status := 'active';
      elsif s.grace_period_ends_at > now() then v_status := 'past_due';
      else v_status := 'expired'; end if;
    when 'past_due' then v_status := case when s.grace_period_ends_at > now() then 'past_due' else 'expired' end;
    when 'canceled' then v_status := case when s.cancel_at_period_end and s.current_period_end > now() then 'active' else 'canceled' end;
    else v_status := s.status;
  end case;
end $$;
revoke all on function public._resolve_subscription_status(uuid) from public, anon, authenticated;

create or replace function public.get_organization_subscription(p_org_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; p public.plans%rowtype; resolved text; plan_id text;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  select * into s from public.subscriptions where organization_id=p_org_id;
  if not found then return jsonb_build_object('found',false,'status','none'); end if;
  select * into p from public.plans where id=s.plan_id;
  select * into resolved,plan_id from public._resolve_subscription_status(p_org_id);
  return jsonb_build_object('found',true,'subscription_id',s.id,'organization_id',s.organization_id,'plan_id',s.plan_id,
    'plan_name',p.name,'plan_slug',p.slug,'monthly_price',p.monthly_price_mmk,'yearly_price',p.yearly_price_mmk,
    'status',resolved,'stored_status',s.status,'billing_cycle',s.billing_cycle,'starts_at',s.starts_at,
    'trial_ends_at',s.trial_ends_at,'current_period_start',s.current_period_start,'current_period_end',s.current_period_end,
    'grace_period_ends_at',s.grace_period_ends_at,'cancel_at_period_end',s.cancel_at_period_end,'expires_at',s.expires_at);
end $$;
revoke all on function public.get_organization_subscription(uuid) from public, anon;
grant execute on function public.get_organization_subscription(uuid) to authenticated;

create or replace function public.get_organization_feature_limit(p_org_id uuid, p_feature_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.features%rowtype; o public.organization_feature_overrides%rowtype; lim integer;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  select * into f from public.features where feature_key = p_feature_key and is_active;
  if not found then return jsonb_build_object('limit_value', 0, 'has_override', false, 'feature_key', p_feature_key); end if;
  select * into o from public.organization_feature_overrides
   where organization_id = p_org_id and feature_id = f.id and limit_override is not null
     and starts_at <= now() and (expires_at is null or expires_at > now())
   order by created_at desc limit 1;
  if found then return jsonb_build_object('limit_value', o.limit_override, 'has_override', true, 'feature_key', p_feature_key); end if;
  select pfl.limit_value into lim from public.subscriptions s join public.plan_feature_limits pfl on pfl.plan_id = s.plan_id
   where s.organization_id = p_org_id and pfl.feature_id = f.id;
  return jsonb_build_object('limit_value', coalesce(lim, -1), 'has_override', false, 'feature_key', p_feature_key);
end $$;
revoke all on function public.get_organization_feature_limit(uuid,text) from public, anon;
grant execute on function public.get_organization_feature_limit(uuid,text) to authenticated;

create or replace function public.get_organization_usage(p_org_id uuid, p_feature_key text)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer := 0;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  case p_feature_key
    when 'max_users' then select count(*)::int into n from public.organization_members where organization_id=p_org_id and is_active;
    when 'max_products' then select count(*)::int into n from public.products where organization_id=p_org_id and is_active;
    when 'max_customers' then select count(*)::int into n from public.customers where organization_id=p_org_id and is_active;
    when 'max_suppliers' then select count(*)::int into n from public.suppliers where organization_id=p_org_id and is_active;
    when 'max_branches' then n := 1;
    else n := 0;
  end case;
  return n;
end $$;
revoke all on function public.get_organization_usage(uuid,text) from public, anon;
grant execute on function public.get_organization_usage(uuid,text) to authenticated;

create or replace function public.check_organization_feature(p_org_id uuid, p_feature_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare st text; pid text; f public.features%rowtype; o public.organization_feature_overrides%rowtype; enabled boolean;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  select * into st, pid from public._resolve_subscription_status(p_org_id);
  select * into f from public.features where feature_key=p_feature_key and is_active;
  if not found then return jsonb_build_object('is_allowed',false,'feature_key',p_feature_key,'reason','Feature not found','subscription_status',st); end if;
  select * into o from public.organization_feature_overrides where organization_id=p_org_id and feature_id=f.id
    and starts_at<=now() and (expires_at is null or expires_at>now()) order by created_at desc limit 1;
  if found and o.is_enabled is not null then
    return jsonb_build_object('is_allowed',o.is_enabled,'feature_key',p_feature_key,'reason','Organization override','subscription_status',st);
  end if;
  if st not in ('active','trialing') then
    return jsonb_build_object('is_allowed',false,'feature_key',p_feature_key,'reason','Subscription '||st,'subscription_status',st);
  end if;
  select is_enabled into enabled from public.plan_features where plan_id=pid and feature_id=f.id;
  return jsonb_build_object('is_allowed',coalesce(enabled,false),'feature_key',p_feature_key,
    'reason',case when enabled then 'Included in '||pid||' plan' else 'Not included in plan' end,'subscription_status',st);
end $$;
revoke all on function public.check_organization_feature(uuid,text) from public, anon;
grant execute on function public.check_organization_feature(uuid,text) to authenticated;

create or replace function public.check_organization_limit(p_org_id uuid, p_feature_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare st text; pid text; li jsonb; feature_access jsonb; lim int; used int; allowed boolean; feature_key text;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  select * into st, pid from public._resolve_subscription_status(p_org_id);
  feature_key := case p_feature_key when 'max_users' then 'max_users' when 'max_products' then 'product_management'
    when 'max_customers' then 'customer_management' when 'max_suppliers' then 'supplier_management' else p_feature_key end;
  li := public.get_organization_feature_limit(p_org_id,p_feature_key);
  feature_access := public.check_organization_feature(p_org_id,feature_key);
  lim := coalesce((li->>'limit_value')::int, -1);
  used := public.get_organization_usage(p_org_id,p_feature_key);
  allowed := coalesce((feature_access->>'is_allowed')::boolean,false) and (lim=-1 or used<lim);
  return jsonb_build_object('is_allowed',allowed,'feature_key',p_feature_key,'current_usage',used,'limit_value',lim,
    'remaining_usage',case when lim=-1 then -1 else greatest(0,lim-used) end,'subscription_status',st,
    'reason',case when st not in ('active','trialing') then 'Subscription '||st when allowed then 'Within limit' else 'Limit reached' end);
end $$;
revoke all on function public.check_organization_limit(uuid,text) from public, anon;
grant execute on function public.check_organization_limit(uuid,text) to authenticated;

create or replace function public.get_organization_entitlements(p_org_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb := '[]'::jsonb; f record; access jsonb; lim jsonb; used int; limit_value int;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  for f in select feature_key,name,feature_type,category from public.features where is_active order by category,name loop
    access := public.check_organization_feature(p_org_id,f.feature_key);
    limit_value := null; used := null;
    if f.feature_type='limit' then
      lim := public.get_organization_feature_limit(p_org_id,f.feature_key);
      limit_value := (lim->>'limit_value')::int;
      used := public.get_organization_usage(p_org_id,f.feature_key);
    end if;
    result := result || jsonb_build_object('feature_key',f.feature_key,'feature_name',f.name,'feature_type',f.feature_type,
      'category',f.category,'is_allowed',(access->>'is_allowed')::boolean,'reason',access->>'reason',
      'current_usage',used,'limit_value',limit_value,'remaining_usage',case when limit_value is null then null when limit_value=-1 then -1 else greatest(0,limit_value-used) end,
      'subscription_status',access->>'subscription_status');
  end loop;
  return result;
end $$;
revoke all on function public.get_organization_entitlements(uuid) from public, anon;
grant execute on function public.get_organization_entitlements(uuid) to authenticated;

create or replace function public.enforce_plan_entitlements()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare org_id uuid; key text; feature_key text; usage_key text; check_result jsonb; is_new boolean;
begin
  org_id := coalesce(new.organization_id, old.organization_id);
  key := tg_argv[0]; usage_key := tg_argv[1];
  is_new := tg_op='INSERT' or (tg_op='UPDATE' and coalesce(old.is_active,true)=false and coalesce(new.is_active,true));
  if not is_new then return new; end if;
  -- The initial owner is inserted before the trial row by organization bootstrap.
  if usage_key='max_users' and not exists(select 1 from public.subscriptions where organization_id=org_id)
     and not exists(select 1 from public.organization_members where organization_id=org_id and is_active)
     and new.user_id=auth.uid() and new.role='owner' then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended(org_id::text||':'||usage_key,0));
  feature_key := case usage_key when 'max_products' then 'product_management' when 'max_users' then 'max_users'
    when 'max_customers' then 'customer_management' when 'max_suppliers' then 'supplier_management' else key end;
  check_result := public.check_organization_feature(org_id,feature_key);
  if not coalesce((check_result->>'is_allowed')::boolean,false) then raise exception 'This feature is not available: %', check_result->>'reason'; end if;
  if usage_key is not null then
    check_result := public.check_organization_limit(org_id,usage_key);
    if not coalesce((check_result->>'is_allowed')::boolean,false) then raise exception 'Plan limit reached: %',check_result->>'reason'; end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_enforce_product_plan_limit on public.products;
create trigger trg_enforce_product_plan_limit before insert or update of is_active on public.products
for each row execute function public.enforce_plan_entitlements('product_management','max_products');
drop trigger if exists trg_enforce_user_plan_limit on public.organization_members;
create trigger trg_enforce_user_plan_limit before insert or update of is_active on public.organization_members
for each row execute function public.enforce_plan_entitlements('user_management','max_users');
drop trigger if exists trg_enforce_customer_plan_limit on public.customers;
create trigger trg_enforce_customer_plan_limit before insert or update of is_active on public.customers
for each row execute function public.enforce_plan_entitlements('customer_management','max_customers');
drop trigger if exists trg_enforce_supplier_plan_limit on public.suppliers;
create trigger trg_enforce_supplier_plan_limit before insert or update of is_active on public.suppliers
for each row execute function public.enforce_plan_entitlements('supplier_management','max_suppliers');

create or replace function public.enforce_feature_access_on_write()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare org_id uuid; feature_key text; result jsonb;
begin
  org_id := new.organization_id;
  feature_key := tg_argv[0];
  result := public.check_organization_feature(org_id,feature_key);
  if not coalesce((result->>'is_allowed')::boolean,false) then raise exception 'This feature is not available: %',result->>'reason'; end if;
  if tg_table_name='sales' and tg_op='UPDATE' and new.status='confirmed' and old.status is distinct from 'confirmed' then
    feature_key := case new.payment_status when 'paid' then 'cash_sales' when 'partial' then 'partial_payments' else 'credit_sales' end;
    result := public.check_organization_feature(org_id,feature_key);
    if not coalesce((result->>'is_allowed')::boolean,false) then raise exception 'This sale type is not available on the current plan: %',feature_key; end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_sales_plan_feature on public.sales;
create trigger trg_sales_plan_feature before insert or update of status on public.sales
for each row execute function public.enforce_feature_access_on_write('sales_management');
drop trigger if exists trg_purchases_plan_feature on public.purchases;
create trigger trg_purchases_plan_feature before insert on public.purchases
for each row execute function public.enforce_feature_access_on_write('purchase_management');
drop trigger if exists trg_categories_plan_feature on public.product_categories;
create trigger trg_categories_plan_feature before insert or update on public.product_categories
for each row execute function public.enforce_feature_access_on_write('category_management');
drop trigger if exists trg_units_plan_feature on public.units;
create trigger trg_units_plan_feature before insert or update on public.units
for each row execute function public.enforce_feature_access_on_write('product_management');
drop trigger if exists trg_expenses_plan_feature on public.expenses;
create trigger trg_expenses_plan_feature before insert on public.expenses
for each row execute function public.enforce_feature_access_on_write('expense_management');
drop trigger if exists trg_stock_adjustments_plan_feature on public.stock_adjustments;
create trigger trg_stock_adjustments_plan_feature before insert on public.stock_adjustments
for each row execute function public.enforce_feature_access_on_write('stock_adjustment');

create or replace function public.enforce_stock_movement_plan_feature()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare required_feature text; result jsonb;
begin
  required_feature := case new.movement_type
    when 'adjustment_in' then 'stock_adjustment'
    when 'adjustment_out' then 'stock_adjustment'
    when 'customer_return' then 'sales_management'
    when 'supplier_return' then 'supplier_payables'
    else null
  end;
  if required_feature is not null then
    result := public.check_organization_feature(new.organization_id,required_feature);
    if not coalesce((result->>'is_allowed')::boolean,false) then raise exception 'This stock operation is not available on the current plan: %',required_feature; end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_stock_movement_plan_feature on public.stock_movements;
create trigger trg_stock_movement_plan_feature before insert on public.stock_movements
for each row execute function public.enforce_stock_movement_plan_feature();

-- Payment request and approval are linked to the existing event history and are idempotent.
create or replace function public.submit_subscription_payment(p_org_id uuid,p_plan_id text,p_billing_cycle text,p_payment_method text,p_reference_number text,p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; p public.plans%rowtype; amount_due numeric(12,2); event_id uuid;
begin
  if not (public.is_org_admin_or_owner(p_org_id) or public.is_platform_admin()) then raise exception 'Unauthorized to submit subscription payment'; end if;
  if p_billing_cycle not in ('monthly','yearly') or nullif(trim(p_reference_number),'') is null then raise exception 'Valid billing cycle and payment reference are required'; end if;
  select * into s from public.subscriptions where organization_id=p_org_id for update;
  if not found then raise exception 'Subscription record not found'; end if;
  select * into p from public.plans where id=p_plan_id and is_active and is_public;
  if not found then raise exception 'Plan is unavailable'; end if;
  if exists(select 1 from public.subscription_events where organization_id=p_org_id and event_type='payment_submitted' and payment_reference=trim(p_reference_number)) then raise exception 'Payment reference already submitted'; end if;
  amount_due := case when p_billing_cycle='yearly' then p.yearly_price_mmk else p.monthly_price_mmk end;
  insert into public.subscription_events(subscription_id,organization_id,event_type,amount,payment_method,payment_reference,admin_notes,plan_id,billing_cycle)
  values(s.id,p_org_id,'payment_submitted',amount_due,p_payment_method,trim(p_reference_number),p_notes,p_plan_id,p_billing_cycle) returning id into event_id;
  insert into public.subscription_payments(subscription_id,organization_id,amount,currency,payment_method,transaction_reference,payment_status,notes,subscription_event_id)
  values(s.id,p_org_id,amount_due,p.currency,p_payment_method,trim(p_reference_number),'pending',p_notes,event_id);
  return jsonb_build_object('success',true,'event_id',event_id,'amount',amount_due,'plan_id',p_plan_id,'billing_cycle',p_billing_cycle);
end $$;
revoke all on function public.submit_subscription_payment(uuid,text,text,text,text,text) from public, anon;
grant execute on function public.submit_subscription_payment(uuid,text,text,text,text,text) to authenticated;

create or replace function public.initialize_organization_trial(p_org_id uuid,p_plan_id text default 'starter')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.plans%rowtype; s public.subscriptions%rowtype; sub_id uuid; period_end timestamptz;
begin
  if not (public.is_org_admin_or_owner(p_org_id) or public.is_platform_admin()) then raise exception 'Unauthorized to initialize organization trial'; end if;
  select * into s from public.subscriptions where organization_id=p_org_id for update;
  if found then return s.id; end if;
  select * into p from public.plans where id=p_plan_id and is_active and is_public;
  if not found then raise exception 'Selected plan is unavailable'; end if;
  period_end := now() + make_interval(days => p.trial_days);
  insert into public.subscriptions(organization_id,plan_id,status,billing_cycle,starts_at,current_period_start,current_period_end,expires_at,trial_ends_at)
    values(p_org_id,p.id,'trialing','monthly',now(),now(),period_end,period_end,period_end) returning id into sub_id;
  insert into public.usage_limits(organization_id,metric,period_key,current_value,limit_value) values
    (p_org_id,'product_count','lifetime',0,p.max_products),
    (p_org_id,'user_count','lifetime',1,p.max_users),
    (p_org_id,'monthly_sales_count',to_char(now(),'YYYY-MM'),0,p.max_monthly_sales)
    on conflict(organization_id,metric,period_key) do nothing;
  insert into public.subscription_events(subscription_id,organization_id,event_type,admin_notes)
    values(sub_id,p_org_id,'trial_started','Trial started for '||p.trial_days||' days');
  insert into public.subscription_audit_logs(organization_id,subscription_id,action,new_value,performed_by)
    values(p_org_id,sub_id,'trial_started',jsonb_build_object('plan_id',p.id,'trial_ends_at',period_end),auth.uid());
  return sub_id;
end $$;
revoke all on function public.initialize_organization_trial(uuid,text) from public, anon;
grant execute on function public.initialize_organization_trial(uuid,text) to authenticated;

drop function if exists public.verify_subscription_payment(uuid,uuid,boolean,text);
create or replace function public.verify_subscription_payment(p_sub_id uuid,p_event_id uuid,p_approve boolean,p_admin_notes text default null,p_target_plan_id text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; e public.subscription_events%rowtype; pay public.subscription_payments%rowtype; p public.plans%rowtype;
  target_id text; cycle text; duration interval; expected_amount numeric(14,2); old_value jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Platform admin privileges required'; end if;
  select * into s from public.subscriptions where id=p_sub_id for update;
  if not found then raise exception 'Subscription not found'; end if;
  select * into e from public.subscription_events where id=p_event_id and subscription_id=p_sub_id for update;
  if not found or e.event_type <> 'payment_submitted' then raise exception 'Pending payment event not found'; end if;
  select * into pay from public.subscription_payments where subscription_event_id=e.id for update;
  if not found or pay.payment_status <> 'pending' then raise exception 'Payment already processed or missing'; end if;
  if p_approve then
    target_id := coalesce(e.plan_id,s.plan_id);
    if p_target_plan_id is not null and p_target_plan_id <> target_id then raise exception 'Approval plan must match the submitted payment'; end if;
    cycle := coalesce(e.billing_cycle,s.billing_cycle,'monthly');
    select * into p from public.plans where id=target_id and is_active;
    if not found then raise exception 'Plan is unavailable'; end if;
    expected_amount := case when cycle='yearly' then p.yearly_price_mmk else p.monthly_price_mmk end;
    if pay.amount <> expected_amount then raise exception 'Payment amount does not match the selected plan'; end if;
    duration := case when cycle='yearly' then interval '1 year' else interval '1 month' end;
    old_value := jsonb_build_object('plan_id',s.plan_id,'status',s.status,'billing_cycle',s.billing_cycle,'period_end',s.current_period_end);
    update public.subscriptions set plan_id=target_id,billing_cycle=cycle,status='active',starts_at=now(),current_period_start=now(),
      current_period_end=now()+duration,expires_at=now()+duration,trial_ends_at=null,grace_period_ends_at=null,updated_at=now() where id=s.id;
    update public.subscription_payments set payment_status='paid',paid_at=now(),reviewed_by=auth.uid(),notes=coalesce(p_admin_notes,notes) where id=pay.id;
    update public.subscription_events set event_type='payment_approved',admin_notes=p_admin_notes where id=e.id;
    insert into public.subscription_audit_logs(organization_id,subscription_id,action,old_value,new_value,performed_by)
      values(s.organization_id,s.id,'payment_approved',old_value,jsonb_build_object('plan_id',target_id,'status','active','billing_cycle',cycle,'amount',pay.amount),auth.uid());
    return jsonb_build_object('success',true,'status','active','plan_id',target_id,'current_period_end',now()+duration);
  end if;
  update public.subscription_payments set payment_status='failed',reviewed_by=auth.uid(),notes=coalesce(p_admin_notes,notes) where id=pay.id;
  update public.subscription_events set event_type='payment_rejected',admin_notes=p_admin_notes where id=e.id;
  insert into public.subscription_audit_logs(organization_id,subscription_id,action,old_value,new_value,performed_by)
    values(s.organization_id,s.id,'payment_rejected',jsonb_build_object('status',s.status),jsonb_build_object('notes',p_admin_notes),auth.uid());
  return jsonb_build_object('success',true,'status','rejected');
end $$;
revoke all on function public.verify_subscription_payment(uuid,uuid,boolean,text,text) from public, anon;
grant execute on function public.verify_subscription_payment(uuid,uuid,boolean,text,text) to authenticated;

-- Restrict direct configuration writes to platform admins; clients use audited RPCs.
drop policy if exists "Plans readable by all" on public.plans;
create policy "Public plans and admin plan visibility" on public.plans for select
  using ((is_active and is_public) or public.is_platform_admin());
drop policy if exists "features_write_admin" on public.features;
create policy "features_write_admin" on public.features for all using (public.is_platform_admin()) with check (public.is_platform_admin());
drop policy if exists "plan_features_write_admin" on public.plan_features;
create policy "plan_features_write_admin" on public.plan_features for all using (public.is_platform_admin()) with check (public.is_platform_admin());
drop policy if exists "plan_feature_limits_write_admin" on public.plan_feature_limits;
create policy "plan_feature_limits_write_admin" on public.plan_feature_limits for all using (public.is_platform_admin()) with check (public.is_platform_admin());
drop policy if exists "sub_payments_write_admin" on public.subscription_payments;
create policy "sub_payments_write_admin" on public.subscription_payments for all using (public.is_platform_admin()) with check (public.is_platform_admin());

create or replace function public.admin_update_plan_configuration(p_plan jsonb,p_features jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare pid text; entry jsonb; fid uuid; old_plan jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Platform admin privileges required'; end if;
  pid := p_plan->>'id';
  select to_jsonb(p) into old_plan from public.plans p where p.id=pid for update;
  if old_plan is null then
    insert into public.plans(id,name,description,slug,price,billing_interval,monthly_price_mmk,yearly_price_mmk,trial_days,
      max_users,max_products,max_monthly_sales,features,is_active,is_public,display_order,currency,max_customers,max_suppliers,max_branches)
    values(pid,p_plan->>'name',p_plan->>'description',p_plan->>'slug',(p_plan->>'monthly_price_mmk')::numeric,'month',
      (p_plan->>'monthly_price_mmk')::numeric,(p_plan->>'yearly_price_mmk')::numeric,14,
      coalesce((p_plan->>'max_users')::integer,1),coalesce((p_plan->>'max_products')::integer,100),-1,'{}'::jsonb,
      coalesce((p_plan->>'is_active')::boolean,false),coalesce((p_plan->>'is_public')::boolean,false),coalesce((p_plan->>'display_order')::integer,0),
      coalesce(p_plan->>'currency','MMK'),coalesce((p_plan->>'max_customers')::integer,100),coalesce((p_plan->>'max_suppliers')::integer,20),coalesce((p_plan->>'max_branches')::integer,1));
  else
    update public.plans set name=p_plan->>'name',description=p_plan->>'description',slug=p_plan->>'slug',
      monthly_price_mmk=(p_plan->>'monthly_price_mmk')::numeric,yearly_price_mmk=(p_plan->>'yearly_price_mmk')::numeric,
      price=(p_plan->>'monthly_price_mmk')::numeric,
      max_users=coalesce((p_plan->>'max_users')::integer,max_users),max_products=coalesce((p_plan->>'max_products')::integer,max_products),
      max_customers=coalesce((p_plan->>'max_customers')::integer,max_customers),max_suppliers=coalesce((p_plan->>'max_suppliers')::integer,max_suppliers),
      max_branches=coalesce((p_plan->>'max_branches')::integer,max_branches),is_active=(p_plan->>'is_active')::boolean,
      is_public=(p_plan->>'is_public')::boolean,display_order=(p_plan->>'display_order')::integer,updated_at=now()
      where id=pid;
  end if;
  for entry in select value from jsonb_array_elements(coalesce(p_features,'[]'::jsonb)) loop
    select id into fid from public.features where feature_key=entry->>'feature_key';
    if fid is null then raise exception 'Unknown feature %',entry->>'feature_key'; end if;
    insert into public.plan_features(plan_id,feature_id,is_enabled) values(pid,fid,coalesce((entry->>'is_enabled')::boolean,false))
      on conflict(plan_id,feature_id) do update set is_enabled=excluded.is_enabled,updated_at=now();
    if entry ? 'limit_value' then
      insert into public.plan_feature_limits(plan_id,feature_id,limit_value,limit_unit) values(pid,fid,(entry->>'limit_value')::integer,entry->>'limit_unit')
        on conflict(plan_id,feature_id) do update set limit_value=excluded.limit_value,limit_unit=excluded.limit_unit,updated_at=now();
      update public.plans set
        max_users=case when entry->>'feature_key'='max_users' then (entry->>'limit_value')::integer else max_users end,
        max_products=case when entry->>'feature_key'='max_products' then (entry->>'limit_value')::integer else max_products end,
        max_customers=case when entry->>'feature_key'='max_customers' then (entry->>'limit_value')::integer else max_customers end,
        max_suppliers=case when entry->>'feature_key'='max_suppliers' then (entry->>'limit_value')::integer else max_suppliers end,
        max_branches=case when entry->>'feature_key'='max_branches' then (entry->>'limit_value')::integer else max_branches end
        where id=pid;
    end if;
  end loop;
  insert into public.subscription_audit_logs(action,old_value,new_value,performed_by)
    values('plan_configuration_updated',old_plan,p_plan,auth.uid());
  return jsonb_build_object('success',true,'plan_id',pid);
end $$;
grant execute on function public.admin_update_plan_configuration(jsonb,jsonb) to authenticated;
revoke all on function public.admin_update_plan_configuration(jsonb,jsonb) from public, anon;

revoke all on function public.get_organization_subscription(uuid) from public, anon;
grant execute on function public.get_organization_subscription(uuid) to authenticated;
revoke all on function public.admin_change_organization_plan(uuid,text,text,integer) from public, anon;
grant execute on function public.admin_change_organization_plan(uuid,text,text,integer) to authenticated;
revoke all on function public.admin_grant_feature_override(uuid,text,boolean,integer,timestamptz,text) from public, anon;
grant execute on function public.admin_grant_feature_override(uuid,text,boolean,integer,timestamptz,text) to authenticated;

-- Plan entitlements also constrain direct table reads, not only React routes.
create or replace function public.organization_has_plan_feature(p_org_id uuid,p_feature_key text)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare decision jsonb;
begin
  if public.is_platform_admin() then return true; end if;
  if not public.has_org_membership(p_org_id) then return false; end if;
  decision := public.check_organization_feature(p_org_id,p_feature_key);
  return coalesce((decision->>'is_allowed')::boolean,false);
end $$;
revoke all on function public.organization_has_plan_feature(uuid,text) from public, anon;
grant execute on function public.organization_has_plan_feature(uuid,text) to authenticated;

drop policy if exists plan_entitlement_select on public.products;
create policy plan_entitlement_select on public.products as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'product_management'));
drop policy if exists plan_entitlement_select on public.product_categories;
create policy plan_entitlement_select on public.product_categories as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'category_management'));
drop policy if exists plan_entitlement_select on public.units;
create policy plan_entitlement_select on public.units as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'product_management'));
drop policy if exists plan_entitlement_select on public.customers;
create policy plan_entitlement_select on public.customers as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'customer_management'));
drop policy if exists plan_entitlement_select on public.suppliers;
create policy plan_entitlement_select on public.suppliers as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'supplier_management'));
drop policy if exists plan_entitlement_select on public.sales;
create policy plan_entitlement_select on public.sales as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'sales_management'));
drop policy if exists plan_entitlement_select on public.purchases;
create policy plan_entitlement_select on public.purchases as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'purchase_management'));
drop policy if exists plan_entitlement_select on public.expenses;
create policy plan_entitlement_select on public.expenses as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'expense_management'));
drop policy if exists plan_entitlement_select on public.stock_movements;
create policy plan_entitlement_select on public.stock_movements as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'inventory_management'));
