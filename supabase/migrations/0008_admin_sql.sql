-- 0008: add a login from the SQL Editor only (for extra admins).
-- private.admin_add_user_sql(name, mobile, pin, role) creates the Supabase Auth user with a hidden email
-- (91<mobile>.<random>@fcl.local) and the PIN stored only as a bcrypt hash, plus the profile row.
-- It lives in the private schema and nobody but the database owner may run it, so the app can never call it.
-- The mobile and PIN are typed only in the SQL Editor; they are never stored in this repo.
-- Usage:  select private.admin_add_user_sql('Name', '9XXXXXXXXX', '0XXXXX', 'admin');   -- PIN in quotes keeps a leading 0

create extension if not exists pgcrypto with schema extensions;

create or replace function private.admin_add_user_sql(
  p_name text, p_mobile text, p_pin text, p_role text default 'admin', p_domain text default 'fcl.local'
) returns text
language plpgsql security definer set search_path = '' as $$
declare m text := regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'); v_id uuid := gen_random_uuid(); v_email text;
begin
  if length(m) = 12 and left(m, 2) = '91' then m := right(m, 10); end if;
  if m !~ '^[6-9][0-9]{9}$' then raise exception 'The mobile must be 10 digits, starting with 6 to 9'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{6}$' then raise exception 'The PIN must be exactly 6 digits, written in quotes, e.g. ''0XXXXX'''; end if;
  if p_role not in ('admin', 'coadmin', 'staff') then raise exception 'The role must be admin, coadmin or staff'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter a name'; end if;

  -- safe to run twice: nothing happens if this mobile already has a login
  if exists (select 1 from public.profiles where mobile = m)
     or exists (select 1 from auth.users where email like '91' || m || '.%') then
    return 'Nothing done: mobile ' || m || ' already has a login.';
  end if;

  v_email := '91' || m || '.' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8) || '@' || p_domain;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change, email_change_token_new)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
          extensions.crypt(p_pin, extensions.gen_salt('bf', 10)), now(),
          '{"provider": "email", "providers": ["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (v_id::text, v_id, jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true), 'email', now(), now(), now());
  insert into public.profiles (id, name, mobile, role, active) values (v_id, btrim(p_name), m, p_role, true);
  insert into public.activity_log (actor_name, action, entity, entity_id, message)
  values ('System', 'user', 'user', v_id::text, format('Added user %s (%s) from the SQL Editor', btrim(p_name),
          case p_role when 'admin' then 'Admin' when 'coadmin' then 'Co-admin' else 'Staff' end));
  return format('Added %s as %s. Log in with mobile %s and the PIN, then change the PIN in More, Change my PIN.',
                btrim(p_name), p_role, m);
end $$;

revoke all on function private.admin_add_user_sql(text, text, text, text, text) from public;
