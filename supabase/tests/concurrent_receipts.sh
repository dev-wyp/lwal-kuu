#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a disposable local Supabase PostgreSQL URL}"
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }
user_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
key_order="$(uuidgen | tr '[:upper:]' '[:lower:]')"
key_receipt_one="$(uuidgen | tr '[:upper:]' '[:lower:]')"
key_receipt_two="$(uuidgen | tr '[:upper:]' '[:lower:]')"
setup_file="$(mktemp)"; log_one="$(mktemp)"; log_two="$(mktemp)"
trap 'rm -f "$setup_file" "$log_one" "$log_two"' EXIT

cat > "$setup_file" <<SQL
\\set ON_ERROR_STOP on
begin;
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values('$user_id','authenticated','authenticated','receipt-$user_id@example.invalid','',now(),now(),now());
set local role authenticated;
select set_config('request.jwt.claim.sub','$user_id',true);
select public.create_organization('Concurrent Receipt $user_id') as org_id \\gset
select public.create_supplier(:'org_id'::uuid,'Receipt Supplier','SUP-$user_id') as supplier_id \\gset
select public.create_product(:'org_id'::uuid,'RECEIPT-$user_id','Receipt Product',(select id from public.units where org_id=:'org_id'::uuid and code='ea'),null,null,null,1,5,true) as product_id \\gset
select public.create_purchase_order(:'org_id'::uuid,:'supplier_id'::uuid,jsonb_build_array(jsonb_build_object('product_id',:'product_id'::uuid,'quantity',100,'unit_cost',1)),null,0,0,null,'$key_order'::uuid) as purchase_id \\gset
select id as purchase_item_id from public.purchase_items where org_id=:'org_id'::uuid and purchase_id=:'purchase_id'::uuid \\gset
select id as warehouse_id from public.warehouses where org_id=:'org_id'::uuid and is_default \\gset
commit;
select :'org_id' as org_id, :'purchase_id' as purchase_id, :'purchase_item_id' as purchase_item_id, :'warehouse_id' as warehouse_id;
SQL
setup="$(psql -XAt -F '|' "$DATABASE_URL" -f "$setup_file")"
values="$(printf '%s\n' "$setup" | tail -n 1)"
IFS='|' read -r org_id purchase_id purchase_item_id warehouse_id <<< "$values"
for id in "$org_id" "$purchase_id" "$purchase_item_id" "$warehouse_id"; do
  [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || { echo "Invalid test fixture output: $values" >&2; exit 2; }
done

run_receipt() {
  local key="$1" log="$2"
  psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL" >"$log" 2>&1 <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','$user_id',true);
select public.post_goods_receipt(
 '$org_id'::uuid,'$purchase_id'::uuid,'$warehouse_id'::uuid,
 jsonb_build_array(jsonb_build_object('purchase_item_id','$purchase_item_id'::uuid,'quantity_received',80,'quantity_accepted',80,'quantity_rejected',0)),
 'Concurrent receipt test','$key'::uuid
);
commit;
SQL
}
run_receipt "$key_receipt_one" "$log_one" & pid_one=$!
run_receipt "$key_receipt_two" "$log_two" & pid_two=$!
set +e
wait "$pid_one"; result_one=$?
wait "$pid_two"; result_two=$?
set -e
successes=0; failures=0
for result in "$result_one" "$result_two"; do if [[ "$result" -eq 0 ]]; then successes=$((successes+1)); else failures=$((failures+1)); fi; done
check="$(psql -XAt -F '|' "$DATABASE_URL" -v org_id="$org_id" -v purchase_id="$purchase_id" -v product_id="$(psql -XAt "$DATABASE_URL" -c "select product_id from public.purchase_items where org_id='$org_id' and purchase_id='$purchase_id' limit 1")" -v warehouse_id="$warehouse_id" -c "select (select quantity from public.inventory_balances where org_id='$org_id' and product_id=(select product_id from public.purchase_items where org_id='$org_id' and purchase_id='$purchase_id' limit 1) and warehouse_id='$warehouse_id'),(select count(*) from public.goods_receipts where org_id='$org_id' and purchase_id='$purchase_id' and status='posted'),(select coalesce(sum(quantity_received),0) from public.goods_receipt_items where org_id='$org_id' and purchase_id='$purchase_id')")"
IFS='|' read -r stock receipt_count received <<< "$check"
if [[ "$successes" -ne 1 || "$failures" -ne 1 || "$stock" != "80.000000" || "$receipt_count" != "1" || "$received" != "80.000000" ]]; then
  echo "Concurrent receipt acceptance failed (successes=$successes failures=$failures stock=$stock receipts=$receipt_count received=$received)" >&2
  cat "$log_one" "$log_two" >&2
  exit 1
fi
echo "PASS: one receipt committed, one over-receipt rejected, stock=$stock, posted receipts=$receipt_count."
