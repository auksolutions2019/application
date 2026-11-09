-- 0009: seed rows and function permissions (run last)

insert into public.settings (id) values (1) on conflict (id) do nothing;
insert into public.suppliers (code, name) values ('00', 'Customer exchange') on conflict (code) do nothing;

-- RPCs: logged-in users only. Each function checks the role itself.
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
-- The first admin is created once from the SQL editor, never from the app.
revoke execute on function public.bootstrap_first_admin(uuid, text, text) from authenticated;
-- The public warranty check is run only by the warranty-check Edge Function (service key), never by the app.
revoke execute on function public.warranty_lookup(text, text) from authenticated;
grant execute on function public.warranty_lookup(text, text) to service_role;
-- The daily keep-alive call is the only thing the public key may run.
grant execute on function public.ping() to anon;
alter default privileges in schema public revoke execute on functions from public, anon;
