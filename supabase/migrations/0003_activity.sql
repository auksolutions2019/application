-- 0003: activity log, filled by triggers (who, what, when)
-- Messages read like the prototype's log. Lines with costs or what the shop owes are admin_only.

-- Indian money format: ₹1,23,456
create or replace function private.rs(n numeric) returns text
language plpgsql immutable set search_path = '' as $$
declare s text := round(abs(coalesce(n, 0)))::bigint::text; h text;
begin
  if length(s) > 3 then
    h := regexp_replace(left(s, length(s) - 3), '(\d)(?=(\d\d)+$)', '\1,', 'g');
    s := h || ',' || right(s, 3);
  end if;
  return case when n < 0 then '-₹' else '₹' end || s;
end $$;

create or replace function private.log(p_action text, p_entity text, p_entity_id text, p_message text, p_admin_only boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare v_id uuid := auth.uid(); v_name text; v_role text;
begin
  if current_setting('app.no_log', true) = 'on' then return; end if;   -- set during backup import
  select p.name, p.role into v_name, v_role from public.profiles p where p.id = v_id;
  insert into public.activity_log (actor_id, actor_name, actor_role, action, entity, entity_id, message, admin_only)
  values (case when v_name is null then null else v_id end, coalesce(v_name, 'System'), v_role,
          p_action, p_entity, p_entity_id, p_message, p_admin_only);
end $$;

-- Name to show for a customer; sales without a name show the lead source ("OLX customer").
create or replace function private.cust_label(p_name text, p_lead text) returns text
language sql immutable set search_path = '' as $$
  select coalesce(nullif(btrim(p_name), ''), coalesce(p_lead, 'Walk-in') || ' customer')
$$;

create or replace function private.lap_code(p_id uuid) returns text
language sql stable set search_path = '' as $$ select code from public.laptops where id = p_id $$;

-- ---------- laptops ----------
create or replace function private.log_laptops_ins() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    select n.lot_id, count(*) c, min(n.code) first_code,
           max(coalesce(nullif(n.model, ''), nullif(n.shorthand, ''))) model, max(n.notes) note,
           lo.prefix, s.code sup_code
    from new_rows n join public.lots lo on lo.id = n.lot_id join public.suppliers s on s.id = lo.supplier_id
    group by n.lot_id, lo.prefix, s.code
  loop
    if r.sup_code = '00' then
      perform private.log('exchange_in', 'laptop', r.first_code,
        format('Took %s in exchange (%s), new code %s', coalesce(nullif(r.model, ''), 'a laptop'), r.note, r.first_code));
    else
      perform private.log('lot_created', 'lot', r.prefix,
        format('Created lot %s with %s laptop%s', r.prefix, r.c, case when r.c = 1 then '' else 's' end));
    end if;
  end loop;
  return null;
end $$;
create trigger log_ins after insert on public.laptops referencing new table as new_rows
  for each statement execute function private.log_laptops_ins();

create or replace function private.log_laptops_upd() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.shorthand is distinct from old.shorthand then perform private.log('edit', 'laptop', new.code, format('Changed specs of %s to "%s"', new.code, new.shorthand)); end if;
  if new.model     is distinct from old.model     then perform private.log('edit', 'laptop', new.code, format('Changed model of %s to "%s"', new.code, new.model)); end if;
  if new.serial    is distinct from old.serial    then perform private.log('edit', 'laptop', new.code, format('Changed serial of %s to "%s"', new.code, new.serial)); end if;
  if new.grade     is distinct from old.grade     then perform private.log('edit', 'laptop', new.code, format('Changed grade of %s to "%s"', new.code, new.grade)); end if;
  if new.notes     is distinct from old.notes     then perform private.log('edit', 'laptop', new.code, format('Changed notes of %s to "%s"', new.code, new.notes)); end if;
  if new.test_note is distinct from old.test_note then perform private.log('edit', 'laptop', new.code, format('Changed test notes of %s to "%s"', new.code, new.test_note)); end if;
  return null;
end $$;
create trigger log_upd after update on public.laptops for each row execute function private.log_laptops_upd();

-- ---------- costs (admin only) ----------
create or replace function private.log_costs_ins() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    select lo.prefix, sum(n.cost) total
    from new_rows n join public.laptops l on l.id = n.laptop_id join public.lots lo on lo.id = l.lot_id
    where n.source = 'lot'
    group by lo.prefix
  loop
    perform private.log('lot_cost', 'lot', r.prefix, format('Lot cost %s for %s', private.rs(r.total), r.prefix), true);
  end loop;
  return null;
end $$;
create trigger log_ins after insert on public.laptop_costs referencing new table as new_rows
  for each statement execute function private.log_costs_ins();

-- ---------- tests ----------
create or replace function private.log_tests_ins() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select n.laptop_id, n.test from new_rows n where n.result = 'fail' loop
    perform private.log('test_fail', 'laptop', private.lap_code(r.laptop_id),
      format('%s: %s test failed', private.lap_code(r.laptop_id), r.test));
  end loop;
  for r in
    select distinct n.laptop_id from new_rows n
    where n.result = 'pass'
      and (select count(*) from public.laptop_tests t where t.laptop_id = n.laptop_id and t.result = 'pass') = 10
  loop
    perform private.log('tests_passed', 'laptop', private.lap_code(r.laptop_id),
      format('%s passed all tests', private.lap_code(r.laptop_id)));
  end loop;
  return null;
end $$;
create trigger log_ins after insert on public.laptop_tests referencing new table as new_rows
  for each statement execute function private.log_tests_ins();

-- ---------- repairs, photos ----------
create or replace function private.log_repairs() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id);
begin
  if tg_op = 'INSERT' and new.lot_expense_id is not null then
    perform private.log('repair', 'laptop', c, format('Fitted %s from lot stock to %s', new.work, c));
  elsif tg_op = 'INSERT' then
    perform private.log('repair', 'laptop', c, format('Repair on %s: %s, %s', c, new.work, private.rs(new.amount)));
  elsif new.deleted_at is not null and old.deleted_at is null then
    perform private.log('repair_deleted', 'laptop', c, format('Deleted repair on %s: %s, %s', c, new.work, private.rs(new.amount)));
  end if;
  return null;
end $$;
create trigger log_chg after insert or update on public.repairs for each row execute function private.log_repairs();

create or replace function private.log_photos() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id);
begin
  perform private.log('photo', 'laptop', c, format('Added a photo to %s', c));
  return null;
end $$;
create trigger log_ins after insert on public.photos for each row execute function private.log_photos();

-- ---------- sales and payments ----------
create or replace function private.log_sales() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id);
begin
  if tg_op = 'INSERT' then
    perform private.log('sale', 'laptop', c, format('Sold %s to %s for %s', c, private.cust_label(new.customer_name, new.lead_source), private.rs(new.price)));
  elsif new.status = 'returned' and old.status = 'active' then
    perform private.log('return', 'laptop', c, format('%s returned by %s', c, private.cust_label(new.customer_name, new.lead_source)));
  elsif new.status = 'voided' and old.status = 'active' then
    perform private.log('undo_sale', 'laptop', c,
      format('Undid sale of %s to %s, payments reversed%s', c, private.cust_label(new.customer_name, new.lead_source),
             case when coalesce(new.void_reason, '') <> '' then ' (' || new.void_reason || ')' else '' end));
  end if;
  return null;
end $$;
create trigger log_chg after insert or update on public.sales for each row execute function private.log_sales();

create or replace function private.log_sale_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  -- advances carried into a sale, exchanges and reversals are already described by other lines
  if new.booking_payment_id is not null or new.reversal_of is not null or new.method = 'Exchange' then
    return null;
  end if;
  select private.cust_label(sa.customer_name, sa.lead_source) customer_name, l.code into s from public.sales sa join public.laptops l on l.id = sa.laptop_id where sa.id = new.sale_id;
  perform private.log('payment', 'laptop', s.code,
    format('Received %s (%s) from %s for %s', private.rs(new.amount), new.method, s.customer_name, s.code));
  return null;
end $$;
create trigger log_ins after insert on public.sale_payments for each row execute function private.log_sale_payments();

-- ---------- bookings ----------
create or replace function private.log_bookings() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text := private.lap_code(new.laptop_id);
begin
  if tg_op = 'INSERT' then
    perform private.log('booking', 'laptop', c, format('Booked %s for %s', c, private.cust_label(new.customer_name, new.lead_source)));
  elsif new.status = 'cancelled' and old.status = 'open' then
    perform private.log('booking_cancelled', 'laptop', c, format('Cancelled booking of %s by %s%s', c,
      private.cust_label(new.customer_name, new.lead_source),
      case new.advance_status when 'held' then ', advance held for admin or co-admin'
                              when 'kept' then ', advance kept' when 'refunded' then ', advance refunded' else '' end));
  elsif old.advance_status = 'held' and new.advance_status in ('refunded','kept') then
    perform private.log('advance_settled', 'laptop', c, format('Held advance from %s for %s: %s',
      private.cust_label(new.customer_name, new.lead_source), c, new.advance_status));
  end if;
  return null;
end $$;
create trigger log_chg after insert or update on public.bookings for each row execute function private.log_bookings();

create or replace function private.log_booking_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
declare b record;
begin
  select private.cust_label(bo.customer_name, bo.lead_source) customer_name, l.code into b from public.bookings bo join public.laptops l on l.id = bo.laptop_id where bo.id = new.booking_id;
  perform private.log('advance', 'laptop', b.code,
    format('Advance %s (%s) from %s for %s', private.rs(new.amount), new.method, b.customer_name, b.code));
  return null;
end $$;
create trigger log_ins after insert on public.booking_payments for each row execute function private.log_booking_payments();

create or replace function private.log_refunds() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.log('refund', 'refund', new.id::text, format('Refund %s (%s): %s', private.rs(new.amount), new.method, new.note));
  return null;
end $$;
create trigger log_ins after insert on public.refunds for each row execute function private.log_refunds();

-- ---------- suppliers, debts (money lines are admin only) ----------
create or replace function private.log_suppliers() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.code <> '00' then
    perform private.log('supplier', 'supplier', new.code, format('Added supplier %s, %s', new.code, new.name));
  end if;
  return null;
end $$;
create trigger log_ins after insert on public.suppliers for each row execute function private.log_suppliers();

create or replace function private.log_supplier_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text;
begin
  select name into n from public.suppliers where id = new.supplier_id;
  perform private.log('supplier_payment', 'supplier', new.supplier_id::text,
    format('%s %s (%s) to supplier %s', case when new.amount < 0 then 'Reversed payment of' else 'Paid' end,
           private.rs(abs(new.amount)), new.method, n), true);
  return null;
end $$;
create trigger log_ins after insert on public.supplier_payments for each row execute function private.log_supplier_payments();

create or replace function private.log_debts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.log('debt', 'debt', new.id::text, format('Added debt: %s, %s', new.name, private.rs(new.amount)), true);
  elsif new.deleted_at is not null and old.deleted_at is null then
    perform private.log('debt_deleted', 'debt', new.id::text, format('Deleted debt: %s', new.name), true);
  end if;
  return null;
end $$;
create trigger log_chg after insert or update on public.debts for each row execute function private.log_debts();

create or replace function private.log_debt_payments() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text;
begin
  select name into n from public.debts where id = new.debt_id;
  perform private.log('debt_payment', 'debt', new.debt_id::text,
    format('%s %s (%s) for %s', case when new.amount < 0 then 'Reversed payment of' else 'Paid' end,
           private.rs(abs(new.amount)), new.method, n), true);
  return null;
end $$;
create trigger log_ins after insert on public.debt_payments for each row execute function private.log_debt_payments();

-- ---------- lot expenses, shop expenses ----------
create or replace function private.log_lot_expenses() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p text;
begin
  select prefix into p from public.lots where id = new.lot_id;
  if tg_op = 'INSERT' then
    perform private.log('lot_expense', 'lot', p, format('Parts for lot %s: %s x %s, %s', p, new.count, new.type, private.rs(new.amount)));
  elsif new.deleted_at is not null and old.deleted_at is null then
    perform private.log('lot_expense_deleted', 'lot', p, format('Deleted parts for lot %s: %s x %s, %s', p, new.count, new.type, private.rs(new.amount)));
  end if;
  return null;
end $$;
create trigger log_chg after insert or update on public.lot_expenses for each row execute function private.log_lot_expenses();

create or replace function private.log_shop_expenses() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.log('shop_expense', 'shop_expense', new.id::text,
      format('Shop expense: %s %s (%s)%s', new.type, private.rs(new.amount), new.method,
             case when new.note <> '' then ', ' || new.note else '' end), true);
  elsif new.deleted_at is not null and old.deleted_at is null then
    perform private.log('shop_expense_deleted', 'shop_expense', new.id::text,
      format('Deleted shop expense: %s %s', new.type, private.rs(new.amount)), true);
  end if;
  return null;
end $$;
create trigger log_chg after insert or update on public.shop_expenses for each row execute function private.log_shop_expenses();

-- ---------- prices, settings ----------
create or replace function private.log_prices() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform private.log('price', 'model', old.shorthand, format('Set usual price of %s to none', old.shorthand));
  else
    perform private.log('price', 'model', new.shorthand, format('Set usual price of %s to %s', new.shorthand, private.rs(new.price)));
  end if;
  return null;
end $$;
create trigger log_chg after insert or update or delete on public.model_prices for each row execute function private.log_prices();

create or replace function private.log_settings() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.log('settings', 'settings', '1', 'Changed settings');
  return null;
end $$;
create trigger log_upd after update on public.settings for each row execute function private.log_settings();

-- Live sync: both phones listen for new activity lines.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.activity_log;
  end if;
end $$;
