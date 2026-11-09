-- Minimal stand-in for what Supabase provides, so the migrations can run on a local Postgres (PGlite).
-- NOT used on Supabase itself.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create schema extensions;
create extension pgcrypto with schema extensions;
-- the auth.users / auth.identities columns that matter (same names and types as Supabase)
create table auth.users (
  instance_id uuid, id uuid primary key, aud varchar(255), role varchar(255), email varchar(255),
  encrypted_password varchar(255), email_confirmed_at timestamptz, raw_app_meta_data jsonb, raw_user_meta_data jsonb,
  created_at timestamptz, updated_at timestamptz, confirmation_token varchar(255), recovery_token varchar(255),
  email_change varchar(255), email_change_token_new varchar(255), banned_until timestamptz, is_sso_user boolean not null default false);
create table auth.identities (
  id uuid primary key default gen_random_uuid(), provider_id text not null, user_id uuid not null references auth.users(id),
  identity_data jsonb not null, provider text not null, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz,
  unique (provider_id, provider));

-- Same behaviour as Supabase: claims come from the request JWT.
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
