-- Store user supplied AI provider keys encrypted for platform marketing only.
create table if not exists public.platform_ai_credentials (
  provider text primary key check (provider in ('openai', 'gemini')),
  api_key_encrypted text not null,
  configured_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.platform_ai_credentials enable row level security;
revoke all on public.platform_ai_credentials from anon, authenticated;
grant all on public.platform_ai_credentials to service_role;
