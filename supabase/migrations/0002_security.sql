-- 0002: role helpers, integrity triggers, Row Level Security, grants

-- ---------- role helpers ----------
-- Role of the caller, or null when: not logged in, user turned off,
-- or the PIN login (session) is older than 7 days.
create or replace function private.my_role() returns text
language sql stable security definer set search_path = '' as $$
  select p.role
  from public.profiles p
  join public.app_sessions s
    on s.user_id = p.id
   and s.session_id = nullif(auth.jwt() ->> 'session_id', '')::uuid
  where p.id = auth.uid()
    and p.active
    and s.created_at > now() - interval '7 days'
$$;

create or replace function private.is_admin() returns boolean
language sql stable set search_path = '' as $$ select coalesce(private.my_role() = 'admin', false) $$;

create or replace function private.is_user() returns boolean
language sql stable set search_path = '' as $$ select private.my_role() is not null $$;

-- admin or co-admin
create or replace function private.is_manager() returns boolean
language sql stable set search_path = '' as $$ select coalesce(private.my_role() in ('admin','coadmin'), false) $$;

create or replace function private.require_user() returns text
language plpgsql stable set search_path = '' as $$
declare r text := private.my_role();
begin
  if r is null then
    raise exception 'Please log in again.' using errcode = '28000';
  end if;
  return r;
end $$;

create or replace function private.require_admin() returns void
language plpgsql stable set search_path = '' as $$
begin
  if private.require_user() <> 'admin' then
    raise exception 'Only the admin can do this.' using errcode = '42501';
  end if;
end $$;

create or replace function private.require_manager() returns text
language plpgsql stable set search_path = '' as $$
declare r text := private.require_user();
begin
  if r = 'staff' then
    raise exception 'Ask the admin or co-admin to do this.' using errcode = '42501';
  end if;
  return r;
end $$;

-- ---------- integrity: payments are never edited or deleted ----------
create or replace function private.no_edit() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_setting('app.wipe', true) = 'on' then   -- only restore_backup sets this
    return coalesce(old, new);
  end if;
  raise exception 'Payments cannot be changed or deleted. Add a reversal instead.';
end $$;

do $$
declare t text;
begin
  foreach t in array array['sale_payments','booking_payments','supplier_payments','debt_payments','refunds','service_payments']
  loop
    execute format('drop trigger if exists no_edit on public.%I', t);
    execute format('create trigger no_edit before update or delete on public.%I for each row execute function private.no_edit()', t);
  end loop;
end $$;

-- Total paid on a sale can never be above its price, or below zero.
create or replace function private.check_sale_total() returns trigger
language plpgsql set search_path = '' as $$
declare v_price numeric; v_paid numeric;
begin
  select s.price into v_price from public.sales s where s.id = new.sale_id;
  select coalesce(sum(p.amount), 0) into v_paid from public.sale_payments p where p.sale_id = new.sale_id;
  if v_paid > v_price then
    raise exception 'Payments (%) would be more than the price (%).', v_paid, v_price;
  end if;
  if v_paid < 0 then
    raise exception 'Payments on a sale cannot go below zero.';
  end if;
  return null;
end $$;

drop trigger if exists sale_total on public.sale_payments;
create constraint trigger sale_total after insert on public.sale_payments
  for each row execute function private.check_sale_total();

-- A sale price can't be lowered below what is already paid.
create or replace function private.check_sale_price() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.price < (select coalesce(sum(amount), 0) from public.sale_payments where sale_id = new.id) then
    raise exception 'The price cannot be less than what is already paid.';
  end if;
  return new;
end $$;

drop trigger if exists sale_price on public.sales;
create trigger sale_price before update of price on public.sales
  for each row execute function private.check_sale_price();

-- ---------- Row Level Security ----------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
alter table private.rpc_requests enable row level security;

-- Nothing is reachable by default; then grant reading table by table.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- Readable by every active user (admin, co-admin, staff)
do $$
declare t text;
begin
  foreach t in array array['settings','lots','lot_lines','laptops','laptop_tests','repairs','photos',
    'customers','bookings','booking_payments','sales','sale_payments','returns','refunds','model_prices',
    'service_partners','service_jobs','sync_ticks']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists user_read on public.%I', t);
    execute format('create policy user_read on public.%I for select to authenticated using (private.is_user())', t);
  end loop;
end $$;

-- Admin and co-admin: suppliers, parts bought for lots
do $$
declare t text;
begin
  foreach t in array array['suppliers','lot_expenses']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists manager_read on public.%I', t);
    execute format('create policy manager_read on public.%I for select to authenticated using (private.is_manager())', t);
  end loop;
end $$;

-- Admin only: purchase costs, what the shop owes and spends
do $$
declare t text;
begin
  foreach t in array array['laptop_costs','lot_line_costs','supplier_payments','debts','debt_payments','shop_expenses',
    'service_charges','service_payments']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists admin_read on public.%I', t);
    execute format('create policy admin_read on public.%I for select to authenticated using (private.is_admin())', t);
  end loop;
end $$;

-- Profiles: own row, or all rows for admin
grant select on public.profiles to authenticated;
drop policy if exists own_or_admin on public.profiles;
create policy own_or_admin on public.profiles for select to authenticated
  using (id = auth.uid() or private.is_admin());

-- Activity: co-admin never sees admin-only lines (costs, supplier and debt money); staff sees none
grant select on public.activity_log to authenticated;
drop policy if exists read_log on public.activity_log;
create policy read_log on public.activity_log for select to authenticated
  using (private.is_admin() or (private.is_manager() and not admin_only));

-- Laptop details every user may edit directly (everything else goes through RPCs)
grant update (brand, brand_other, model, processor, processor_other, gen, ram_gb, storage_type, storage_gb,
              serial, grade, notes, test_note) on public.laptops to authenticated;
drop policy if exists staff_edit on public.laptops;
create policy staff_edit on public.laptops for update to authenticated
  using (private.is_user()) with check (private.is_user());

-- app_sessions, login_attempts: no policies = no access except the service role (Edge Functions).

-- Helpers called inside policies must be executable by the caller.
revoke all on all functions in schema private from public;
grant execute on function private.my_role(), private.is_admin(), private.is_manager(), private.is_user() to authenticated;
-- Pure helpers used by column defaults, checks and the generated shorthand when a user edits a laptop.
grant execute on function private.today(), private.ordinal(int), private.brands(), private.processors(), private.lead_sources(),
  private.shorthand(text, text, text, text, int, int, text, int), private.service_skills() to authenticated;
alter default privileges in schema private revoke execute on functions from public;
