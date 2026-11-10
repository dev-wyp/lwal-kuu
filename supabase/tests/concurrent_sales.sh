#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a disposable local Supabase PostgreSQL URL}"
command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }

user_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
key_one="$(uuidgen | tr '[:upper:]' '[:lower:]')"
key_two="$(uuidgen | tr '[:upper:]' '[:lower:]')"
setup_file="$(mktemp)"
log_one="$(mktemp)"
log_two="$(mktemp)"
trap 'rm -f "$setup_file" "$log_one" "$log_two"' EXIT

cat > "$setup_file" <<SQL
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values ('$user_id', 'authenticated', 'authenticated', 'concurrency-$user_id@example.invalid', '', now(), now(), now());
set local role authenticated;
select set_config('request.jwt.claim.sub', '$user_id', true);
select public.create_organization('Concurrent Sales $user_id') as org_id \gset
select public.create_product(
  :'org_id'::uuid,
  'LIMITED-$user_id',
  'Limited Stock $user_id',
  (select id from public.units where org_id = :'org_id'::uuid and code = 'ea'),
  null, null, null, 1, 10, true
) as product_id \gset
select public.adjust_inventory(
  :'org_id'::uuid,
  :'product_id'::uuid,
  (select id from public.warehouses where org_id = :'org_id'::uuid and is_default),
  10,
  'Concurrent sales test opening stock',
  '$key_one'::uuid
);
commit;
select :'org_id' as org_id;
select :'product_id' as product_id;
SQL

setup_output="$(psql -XAt -F '|' "$DATABASE_URL" -f "$setup_file")"
org_id="$(printf '%s\n' "$setup_output" | tail -n 2 | head -n 1)"
product_id="$(printf '%s\n' "$setup_output" | tail -n 1)"
if [[ ! "$org_id" =~ ^[0-9a-f-]{36}$ || ! "$product_id" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "Could not read test organization/product IDs from setup output:" >&2
  printf '%s\n' "$setup_output" >&2
  exit 2
fi

run_sale() {
  local key="$1"
  psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL" >"$2" 2>&1 <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$user_id', true);
select public.create_sale(
  '$org_id'::uuid,
  jsonb_build_array(jsonb_build_object('product_id', '$product_id'::uuid, 'quantity', 7)),
  null,
  'cash',
  '$key'::uuid
);
commit;
SQL
}

run_sale "$key_one" "$log_one" & pid_one=$!
run_sale "$key_two" "$log_two" & pid_two=$!
set +e
wait "$pid_one"; result_one=$?
wait "$pid_two"; result_two=$?
set -e

successes=0
failures=0
for result in "$result_one" "$result_two"; do
  if [[ "$result" -eq 0 ]]; then successes=$((successes + 1)); else failures=$((failures + 1)); fi
done

check_output="$(psql -XAt -F '|' "$DATABASE_URL" -v org_id="$org_id" -v product_id="$product_id" <<'SQL'
select
  (select quantity from public.inventory_balances where org_id = :'org_id'::uuid and product_id = :'product_id'::uuid),
  (select count(*) from public.sales where org_id = :'org_id'::uuid and created_by is not null and status = 'posted'),
  (select count(*) from public.stock_movements where org_id = :'org_id'::uuid and movement_type = 'sale');
SQL
)"
IFS='|' read -r remaining sale_count movement_count <<< "$check_output"
if [[ "$successes" -ne 1 || "$failures" -ne 1 || "$remaining" != "3.000000" || "$sale_count" != "1" || "$movement_count" != "1" ]]; then
  echo "Concurrent sale acceptance failed (successes=$successes failures=$failures remaining=$remaining sales=$sale_count movements=$movement_count)" >&2
  cat "$log_one" "$log_two" >&2
  exit 1
fi

echo "PASS: one sale committed, one was rejected, remaining stock=$remaining, sales=$sale_count, movements=$movement_count."
