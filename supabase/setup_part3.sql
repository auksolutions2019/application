-- =====================================================================
-- First Choice Laptops, Stock Manager: database setup, PART 3 OF 3
-- Generated from supabase/migrations by tools/build-setup.mjs. Do not edit by hand.
-- The same SQL as setup_all.sql, split because the SQL Editor may refuse one big query.
-- Run the parts in order (1, 2, 3), each in a new query. All are safe to run again.
-- The last result shows how many tables were made and how many have access rules on.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0007_backup_import.sql
-- ---------------------------------------------------------------------
-- 0007: backup, restore and one-time imports (admin only)
--   export_backup()                 full copy of the business data as JSON ("fcl-v2")
--   restore_backup(json, 'RESTORE') wipes the business data and loads a backup (fcl-v2 or an old prototype backup)
--   import_backup(json)             one-time load of a prototype backup into an empty database
--   import_excel(plan)              one-time load of the dealer's Excel, after the preview is approved
-- Users (profiles, logins) are never touched.

-- Tables in load order (parents first).
create or replace function private.backup_tables() returns text[] language sql immutable as $$
  select array['settings','suppliers','lots','lot_lines','lot_line_costs','laptops','laptop_costs','laptop_tests',
    'lot_expenses','repairs','photos','customers','bookings','booking_payments','invoices','sales','sale_payments','returns',
    'refunds','supplier_payments','debts','debt_payments','shop_expenses','model_prices','service_partners',
    'service_jobs','service_charges','service_payments','activity_log',
    'accessories','accessory_moves','accessory_move_costs','notifications','notification_reads']
$$;

create or replace function public.export_backup()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t text; v jsonb; tabs jsonb := '{}';
begin
  perform private.require_admin();
  foreach t in array private.backup_tables() loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x) order by %s), ''[]'') from public.%I x',
                   case when t = 'activity_log' then 'x.id' else 'x.created_at' end, t) into v;
    tabs := tabs || jsonb_build_object(t, v);
  end loop;
  -- Recently deleted (30 days), so a restored backup can still restore those items
  perform private.log('export', 'export', 'json', 'Exported a JSON backup (all data)');
  tabs := tabs || jsonb_build_object('deletions', coalesce((select jsonb_agg(to_jsonb(d) order by d.deleted_at) from private.deletions d), '[]'));
  return jsonb_build_object('format', 'fcl-v2', 'exported_at', now(), 'tables', tabs);
end $$;

create or replace function private.wipe_business_data() returns void
language plpgsql set search_path = '' as $$
declare t text; list text := '';
begin
  foreach t in array private.backup_tables() loop list := list || ', public.' || quote_ident(t); end loop;
  execute 'truncate ' || substr(list, 3) || ', public.sync_ticks, private.rpc_requests, private.deletions restart identity cascade';
end $$;

-- Generic loader for an fcl-v2 backup: every table, every column (except generated ones).
-- Links to users that do not exist in this project are cleared rather than failing.
create or replace function private.load_v2(d jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare t text; cols text; exprs text; n int; counts jsonb := '{}';
begin
  foreach t in array private.backup_tables() loop
    if jsonb_typeof(d -> 'tables' -> t) is distinct from 'array' then continue; end if;
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
           string_agg(case when c.column_name in ('created_by','updated_by','deleted_by','voided_by','entered_by',
                                                   'given_by','received_by','advance_decided_by','actor_id')
                           then format('(select p.id from public.profiles p where p.id = x.%I)', c.column_name)
                           else 'x.' || quote_ident(c.column_name) end, ', ' order by c.ordinal_position)
      into cols, exprs
    from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = t and c.is_generated = 'NEVER'
      and not (t = 'activity_log' and c.column_name = 'id');
    execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I, $1) x order by %s',
                   t, cols, exprs, t, case when t = 'activity_log' then 'x.at' else 'x.created_at' end)
      using d -> 'tables' -> t;
    get diagnostics n = row_count;
    counts := counts || jsonb_build_object(t, n);
  end loop;
  return counts;
end $$;

-- ---------- old prototype backups ----------
create or replace function private.guess_brand(t text) returns text language sql immutable set search_path = '' as $$
  select case when t ~* '\mdell\M|latitude|inspiron|vostro' then 'Dell'
              when t ~* '\mhp\M|elitebook|probook|pavilion' then 'HP'
              when t ~* 'lenovo|thinkpad|ideapad|\m[etxl]4[0-9]{2}\M' then 'Lenovo'
              when t ~* '\macer\M|\mascer\M|aspire' then 'Acer'
              when t ~* '\masus\M|vivobook|zenbook' then 'Asus'
              when t ~* 'apple|macbook' then 'Apple' end
$$;
create or replace function private.guess_processor(t text) returns text language sql immutable set search_path = '' as $$
  select case when t ~* '\mi3\M' then 'i3' when t ~* '\mi5\M' then 'i5' when t ~* '\mi7\M' then 'i7' when t ~* '\mi9\M' then 'i9'
              when t ~* 'ryzen ?3' then 'Ryzen 3' when t ~* 'ryzen ?5' then 'Ryzen 5' when t ~* 'ryzen ?7' then 'Ryzen 7'
              when t ~* 'pentium|pentinum' then 'Pentium' when t ~* 'celeron' then 'Celeron' end
$$;
create or replace function private.guess_gen(t text) returns int language sql immutable set search_path = '' as $$
  select nullif(substring(lower(coalesce(t, '')) from '\m([0-9]{1,2}) ?(?:st|nd|rd|th|ed|gen)\M'), '')::int
$$;

create or replace function private.proto_method(p text, p_allow_exchange boolean) returns text
language sql immutable set search_path = '' as $$
  select case when p in ('Cash','UPI','Bank') then p when p = 'Exchange' and p_allow_exchange then 'Exchange' else 'Cash' end
$$;

create or replace function private.load_proto_sale(p_laptop uuid, s jsonb, p_status text) returns uuid
language plpgsql set search_path = '' as $$
declare v_cust uuid; v_sale uuid; p jsonb;
begin
  begin
    v_cust := private.upsert_customer(s ->> 'mobile', s ->> 'name', s ->> 'address', 'Retail');
  exception when others then v_cust := null;    -- unusable mobile in the old data
  end;
  insert into public.sales (laptop_id, customer_id, customer_name, customer_address, lead_source, customer_type,
                            sold_on, price, warranty_months, status)
  values (p_laptop, v_cust, btrim(coalesce(s ->> 'name', '')), btrim(coalesce(s ->> 'address', '')), 'Other', 'Retail',
          (s ->> 'date')::date, (s ->> 'price')::numeric,
          case when v_cust is null then 0 else least(60, greatest(0, coalesce((s ->> 'warranty')::int, 0))) end, p_status)
  returning id into v_sale;
  for p in select * from jsonb_array_elements(coalesce(s -> 'payments', '[]')) loop
    if coalesce((p ->> 'amt')::numeric, 0) > 0 then
      insert into public.sale_payments (sale_id, paid_on, amount, method, ref)
      values (v_sale, coalesce((p ->> 'date')::date, (s ->> 'date')::date), round((p ->> 'amt')::numeric, 2),
              private.proto_method(p ->> 'method', true), coalesce(p ->> 'ref', ''));
    end if;
  end loop;
  return v_sale;
end $$;

create or replace function private.load_prototype(d jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare s jsonb; b jsonb; l jsonb; r jsonb; p jsonb; x record;
        v_sup uuid; v_lot uuid; v_line uuid; v_lap uuid; v_sale uuid; v_bk uuid; v_cust uuid; v_debt uuid;
        v_status text; v_prefix text; v_serial text; v_note text; v_per numeric; v_rest numeric; v_free int;
        n_lap int := 0; n_sale int := 0;
begin
  create temp table if not exists _map (kind text, old text, new uuid, primary key (kind, old)) on commit drop;
  delete from _map;

  s := d -> 'settings';
  if jsonb_typeof(s) = 'object' then
    update public.settings set shop_name = coalesce(nullif(btrim(s ->> 'shopName'), ''), shop_name),
      phone = coalesce(s ->> 'phone', phone), addr = coalesce(s ->> 'addr', addr),
      default_warranty_months = coalesce(least(60, (s ->> 'warranty')::int), default_warranty_months),
      old_days = coalesce(nullif((s ->> 'oldDays')::int, 0), old_days),
      cloud_name = coalesce(s ->> 'cloud', cloud_name), upload_preset = coalesce(s ->> 'preset', upload_preset)
    where id = 1;
  end if;

  for s in select * from jsonb_array_elements(coalesce(d -> 'suppliers', '[]')) loop
    insert into public.suppliers (code, name, phone)
    values (s ->> 'code', coalesce(nullif(btrim(s ->> 'name'), ''), 'Supplier ' || (s ->> 'code')), coalesce(s ->> 'phone', ''))
    on conflict (code) do update set name = excluded.name, phone = excluded.phone
    returning id into v_sup;
    insert into _map values ('sup', s ->> 'id', v_sup);
  end loop;

  for b in select * from jsonb_array_elements(coalesce(d -> 'batches', '[]')) loop
    select new into v_sup from _map where kind = 'sup' and old = b ->> 'supId';
    v_prefix := b ->> 'prefix';
    insert into public.lots (supplier_id, lot_no, month, year, prefix, kind, bought_on, note)
    values (v_sup, (b ->> 'batchNo')::int, (b ->> 'month')::int, (b ->> 'year')::int, v_prefix,
            case when left(v_prefix, 2) = '00' then 'exchange' else 'purchase' end,
            coalesce((b ->> 'date')::date, make_date((b ->> 'year')::int, (b ->> 'month')::int, 1)), 'From the old app')
    returning id into v_lot;
    insert into public.lot_lines (lot_id, line_no, is_mixed, model, qty)
    values (v_lot, 1, left(v_prefix, 2) = '00' or btrim(coalesce(b ->> 'model', '')) = '',
            case when left(v_prefix, 2) = '00' then '' else btrim(coalesce(b ->> 'model', '')) end,
            greatest(1, (select count(*) from jsonb_array_elements(coalesce(d -> 'laptops', '[]')) y where y ->> 'batchId' = b ->> 'id')))
    returning id into v_line;
    insert into _map values ('lot', b ->> 'id', v_lot), ('line', b ->> 'id', v_line);
  end loop;

  for l in select * from jsonb_array_elements(coalesce(d -> 'laptops', '[]')) loop
    select new into v_lot from _map where kind = 'lot' and old = l ->> 'batchId';
    select new into v_line from _map where kind = 'line' and old = l ->> 'batchId';
    v_status := case when jsonb_typeof(l -> 'sale') = 'object' then 'sold'
                     when jsonb_typeof(l -> 'reserve') = 'object' then 'booked' else 'in_stock' end;
    v_serial := btrim(coalesce(l ->> 'serial', ''));
    v_note := btrim(concat_ws('. ', nullif(btrim(coalesce(l ->> 'note', '')), ''),
                              case when coalesce(l ->> 'specs', '') <> '' then 'Specs: ' || (l ->> 'specs') end));
    if v_serial <> '' and exists (select 1 from public.laptops where upper(btrim(serial)) = upper(v_serial)) then
      v_note := btrim(concat_ws('. ', nullif(v_note, ''), 'Same serial as another laptop: ' || v_serial));
      v_serial := '';
    end if;
    insert into public.laptops (lot_id, line_id, piece_no, code, brand, processor, gen, model, serial, grade, status,
                                notes, test_note, tested_on, added_on)
    values (v_lot, v_line, right(l ->> 'code', 3)::int, l ->> 'code',
            private.guess_brand(l ->> 'model'), private.guess_processor(l ->> 'model'), private.guess_gen(l ->> 'model'),
            btrim(coalesce(l ->> 'model', '')), v_serial,
            case when l ->> 'grade' in ('A','B','C') then l ->> 'grade' else '' end, v_status,
            left(v_note, 300), coalesce(l ->> 'testNote', ''), (l ->> 'testedOn')::date,
            coalesce((l ->> 'added')::date, (select bought_on from public.lots where id = v_lot)))
    returning id into v_lap;
    n_lap := n_lap + 1;

    insert into public.laptop_tests (laptop_id, test, result)
    select v_lap, t.k, case when t.v = 'ok' then 'pass' else 'fail' end
    from jsonb_each_text(case when jsonb_typeof(l -> 'tests') = 'object' then l -> 'tests' else '{}' end) as t(k, v)
    where t.v in ('ok','fail')
      and t.k = any (array['Display','Keyboard','Touchpad','Battery','Charging','USB ports','Wi-Fi','Audio','Camera','Storage']);

    insert into public.repairs (laptop_id, work, amount, done_on)
    select v_lap, left(coalesce(nullif(btrim(e ->> 'desc'), ''), 'Repair'), 120), round((e ->> 'amt')::numeric, 2),
           coalesce((e ->> 'date')::date, private.today())
    from jsonb_array_elements(coalesce(l -> 'expenses', '[]')) e where coalesce((e ->> 'amt')::numeric, 0) > 0;

    insert into public.photos (laptop_id, url)
    select v_lap, u from jsonb_array_elements_text(coalesce(l -> 'photos', '[]')) u
    where u ~ '^https://res\.cloudinary\.com/[^\s"''<>]+$';

    if l ->> 'cost' is not null then
      insert into public.laptop_costs (laptop_id, cost, source)
      values (v_lap, round((l ->> 'cost')::numeric, 2), case when left(l ->> 'code', 2) = '00' then 'exchange' else 'import' end);
    end if;

    if v_status = 'sold' then perform private.load_proto_sale(v_lap, l -> 'sale', 'active'); n_sale := n_sale + 1; end if;
    for r in select * from jsonb_array_elements(coalesce(l -> 'returns', '[]')) loop
      v_sale := private.load_proto_sale(v_lap, r, 'returned');
      insert into public.returns (sale_id, laptop_id, returned_on, note)
      values (v_sale, v_lap, coalesce((r ->> 'retDate')::date, (r ->> 'date')::date), 'From the old app');
    end loop;
    if v_status = 'booked' then
      r := l -> 'reserve';
      v_cust := private.upsert_customer(r ->> 'mobile', r ->> 'name', r ->> 'address', 'Retail');
      insert into public.bookings (laptop_id, customer_id, customer_name, customer_address, lead_source, booked_on, agreed_price)
      values (v_lap, v_cust, btrim(coalesce(r ->> 'name', '')), btrim(coalesce(r ->> 'address', '')), 'Other',
              (r ->> 'date')::date, nullif((r ->> 'price')::numeric, 0))
      returning id into v_bk;
      insert into public.booking_payments (booking_id, paid_on, amount, method, ref)
      select v_bk, coalesce((p2 ->> 'date')::date, (r ->> 'date')::date), round((p2 ->> 'amt')::numeric, 2),
             private.proto_method(p2 ->> 'method', false), coalesce(p2 ->> 'ref', '')
      from jsonb_array_elements(coalesce(r -> 'payments', '[]')) p2 where coalesce((p2 ->> 'amt')::numeric, 0) > 0;
    end if;
  end loop;

  -- lot cost: what is left after laptops with their own cost, split over the others (same as the old app)
  for b in select * from jsonb_array_elements(coalesce(d -> 'batches', '[]')) loop
    if left(b ->> 'prefix', 2) = '00' or coalesce((b ->> 'cost')::numeric, 0) <= 0 then continue; end if;
    select new into v_line from _map where kind = 'line' and old = b ->> 'id';
    insert into public.lot_line_costs (line_id, line_cost) values (v_line, round((b ->> 'cost')::numeric, 2));
    select round((b ->> 'cost')::numeric, 2) - coalesce(sum(c.cost), 0) into v_rest
    from public.laptop_costs c join public.laptops x2 on x2.id = c.laptop_id where x2.line_id = v_line;
    select count(*) into v_free from public.laptops x2 where x2.line_id = v_line
      and not exists (select 1 from public.laptop_costs c where c.laptop_id = x2.id);
    if v_free > 0 and v_rest >= 0 then
      v_per := trunc(v_rest / v_free, 2);
      insert into public.laptop_costs (laptop_id, cost, source)
      select q.id, case when q.rn = v_free then v_rest - v_per * (v_free - 1) else v_per end, 'lot'
      from (select x2.id, row_number() over (order by x2.piece_no) rn from public.laptops x2
            where x2.line_id = v_line and not exists (select 1 from public.laptop_costs c where c.laptop_id = x2.id)) q;
    end if;
  end loop;

  for p in select * from jsonb_array_elements(coalesce(d -> 'supPay', '[]')) loop
    if p ->> 'method' = 'Exchange' or coalesce((p ->> 'amt')::numeric, 0) <= 0 then continue; end if;
    select new into v_sup from _map where kind = 'sup' and old = p ->> 'supId';
    if v_sup is null then continue; end if;
    insert into public.supplier_payments (supplier_id, paid_on, amount, method, ref)
    values (v_sup, (p ->> 'date')::date, round((p ->> 'amt')::numeric, 2), private.proto_method(p ->> 'method', false), coalesce(p ->> 'ref', ''));
  end loop;

  for p in select * from jsonb_array_elements(coalesce(d -> 'debts', '[]')) loop
    insert into public.debts (name, type, amount, due_on)
    values (coalesce(nullif(btrim(p ->> 'name'), ''), 'Debt'),
            case when p ->> 'type' in ('Shop rent','Loan','Borrowed','Bill','Other') then p ->> 'type' else 'Other' end,
            round((p ->> 'amount')::numeric, 2), nullif(p ->> 'due', '')::date)
    returning id into v_debt;
    insert into public.debt_payments (debt_id, paid_on, amount, method, ref)
    select v_debt, (q ->> 'date')::date, round((q ->> 'amt')::numeric, 2), private.proto_method(q ->> 'method', false), ''
    from jsonb_array_elements(coalesce(p -> 'payments', '[]')) q where coalesce((q ->> 'amt')::numeric, 0) > 0;
  end loop;

  insert into public.model_prices (shorthand, price)
  select left(btrim(k), 120), round(v::numeric, 2)
  from jsonb_each_text(case when jsonb_typeof(d -> 'prices') = 'object' then d -> 'prices' else '{}' end) as t(k, v)
  where btrim(k) <> '' and v::numeric > 0
  on conflict (shorthand) do nothing;

  insert into public.refunds (refunded_on, amount, method, label)
  select (f ->> 'date')::date, round((f ->> 'amt')::numeric, 2), private.proto_method(f ->> 'method', false), coalesce(f ->> 'note', '')
  from jsonb_array_elements(coalesce(d -> 'refunds', '[]')) f where coalesce((f ->> 'amt')::numeric, 0) > 0;

  insert into public.activity_log (at, actor_name, actor_role, action, message)
  select coalesce((g ->> 't')::timestamptz, now()), case when g ->> 'who' = 'coadmin' then 'Co-admin (old app)' else 'Admin (old app)' end,
         case when g ->> 'who' = 'coadmin' then 'coadmin' else 'admin' end, 'old_app', coalesce(g ->> 'what', '')
  from jsonb_array_elements(coalesce(d -> 'log', '[]')) g;

  return jsonb_build_object('suppliers', (select count(*) from _map where kind = 'sup'),
                            'lots', (select count(*) from _map where kind = 'lot'), 'laptops', n_lap, 'sales', n_sale);
end $$;

create or replace function private.load_any(d jsonb) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if d ->> 'format' = 'fcl-v2' then return private.load_v2(d); end if;
  if jsonb_typeof(d -> 'laptops') = 'array' and jsonb_typeof(d -> 'suppliers') = 'array' then return private.load_prototype(d); end if;
  raise exception 'This is not a backup file from this app or the old app';
end $$;

create or replace function public.restore_backup(p_data jsonb, p_confirm text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  perform private.require_admin();
  if p_confirm is distinct from 'RESTORE' then raise exception 'Type RESTORE to confirm'; end if;
  if not (p_data ->> 'format' = 'fcl-v2' or jsonb_typeof(p_data -> 'laptops') = 'array') then
    raise exception 'This is not a backup file from this app or the old app';
  end if;
  perform set_config('app.no_log', 'on', true);
  perform private.wipe_business_data();
  if p_data ->> 'format' is distinct from 'fcl-v2' then
    insert into public.settings (id) values (1);
    insert into public.suppliers (code, name) values ('00', 'Customer exchange');
  end if;
  v := private.load_any(p_data);
  insert into public.settings (id) values (1) on conflict (id) do nothing;
  insert into public.suppliers (code, name) values ('00', 'Customer exchange') on conflict (code) do nothing;
  if jsonb_typeof(p_data -> 'tables' -> 'deletions') = 'array' then
    insert into private.deletions (id, kind, item_id, label, details, deleted_at, deleted_by, cloud_status, restored_at, restored_by, purged_at)
    select x.id, x.kind, x.item_id, x.label, x.details, x.deleted_at,
           (select p.id from public.profiles p where p.id = x.deleted_by), x.cloud_status, x.restored_at,
           (select p.id from public.profiles p where p.id = x.restored_by), x.purged_at
    from jsonb_populate_recordset(null::private.deletions, p_data -> 'tables' -> 'deletions') x;
  end if;
  perform set_config('app.no_log', 'off', true);
  perform private.log('restore', 'backup', null, 'Restored a backup');
  return v;
end $$;

-- One-time: load an old prototype backup into a database that has no lots yet.
create or replace function public.import_backup(p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  perform private.require_admin();
  if exists (select 1 from public.lots where kind <> 'exchange') or exists (select 1 from public.sales) then
    raise exception 'This database already has data. Use Restore in Backup to replace everything.';
  end if;
  if jsonb_typeof(p_data -> 'laptops') is distinct from 'array' then raise exception 'This is not a backup file from the old app'; end if;
  perform set_config('app.no_log', 'on', true);
  v := private.load_prototype(p_data);
  perform set_config('app.no_log', 'off', true);
  perform private.log('import', 'backup', null, format('Imported the old app backup: %s laptops', v ->> 'laptops'));
  return v;
end $$;

-- ---------- one-time Excel import ----------
-- p: {"lots":[{"key","supplier","lot_no","bought_on","kind","note","lines":[...]}],
--     "expenses":[{"lot_key","spent_on","type","count","amount","method","line_no","note"}],
--     "sales":[{"lot_key","sold_on","price","lead_source","customer_type","name","method","specs":{...}}]}  one sale per laptop
create or replace function public.import_excel(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare lo jsonb; e jsonb; s jsonb; sp jsonb; v_sup uuid; v_no int; v_lot uuid; v_line uuid; v_lap uuid; r jsonb;
        n_sales int := 0; t_sales numeric := 0; n_exp int := 0; t_exp numeric := 0;
begin
  perform private.require_admin();
  if exists (select 1 from public.lots where kind <> 'exchange') or exists (select 1 from public.sales) then
    raise exception 'This database already has lots or sales. The Excel import runs only once, on an empty database.';
  end if;
  perform set_config('app.no_log', 'on', true);
  perform set_config('app.no_invoice', 'on', true);     -- old sales from the Excel get no invoice number
  create temp table if not exists _xl (key text primary key, lot uuid) on commit drop;
  delete from _xl;

  for lo in select * from jsonb_array_elements(coalesce(p -> 'lots', '[]')) loop
    select id into v_sup from public.suppliers where lower(name) = lower(btrim(lo ->> 'supplier')) and code <> '00';
    if v_sup is null then v_sup := (public.add_supplier(btrim(lo ->> 'supplier'), '') ->> 'id')::uuid; end if;
    v_no := (lo ->> 'lot_no')::int;
    if v_no is null or v_no not between 1 and 99 or exists (select 1 from public.lots where supplier_id = v_sup and lot_no = v_no
         and month = extract(month from (lo ->> 'bought_on')::date) and year = extract(year from (lo ->> 'bought_on')::date)) then
      select coalesce(max(lot_no), 0) + 1 into v_no from public.lots where supplier_id = v_sup;
    end if;
    r := public.create_lot(v_sup, v_no, (lo ->> 'bought_on')::date, lo -> 'lines',
                           coalesce(lo ->> 'kind', 'purchase'), coalesce(lo ->> 'note', ''));
    insert into _xl values (lo ->> 'key', (r ->> 'lot_id')::uuid);
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p -> 'expenses', '[]')) loop
    select lot into v_lot from _xl where key = e ->> 'lot_key';
    if v_lot is null then raise exception 'Expense for unknown lot %', e ->> 'lot_key'; end if;
    v_line := null;
    if e ->> 'line_no' is not null then
      select id into v_line from public.lot_lines where lot_id = v_lot and line_no = (e ->> 'line_no')::int;
    end if;
    perform public.add_lot_expense(v_lot, e ->> 'type', (e ->> 'count')::int, (e ->> 'amount')::numeric,
                                   coalesce(e ->> 'method', 'Cash'), v_line, '', coalesce(e ->> 'note', ''), (e ->> 'spent_on')::date);
    n_exp := n_exp + 1; t_exp := t_exp + (e ->> 'amount')::numeric;
  end loop;

  for s in select * from jsonb_array_elements(coalesce(p -> 'sales', '[]')) order by value ->> 'sold_on' loop
    select lot into v_lot from _xl where key = s ->> 'lot_key';
    if v_lot is null then raise exception 'Sale for unknown lot %', s ->> 'lot_key'; end if;
    sp := coalesce(s -> 'specs', '{}');
    -- best unsold laptop in that lot: same model, then same brand/processor/gen, then a Mixed one, then any
    select l.id into v_lap
    from public.laptops l join public.lot_lines ln on ln.id = l.line_id
    where l.lot_id = v_lot and l.status = 'in_stock'
    order by case when not ln.is_mixed and coalesce(sp ->> 'model', '') <> '' and lower(ln.model) = lower(sp ->> 'model') then 0
                  when not ln.is_mixed and ln.brand is not distinct from sp ->> 'brand' and ln.processor is not distinct from sp ->> 'processor'
                       and ln.gen is not distinct from (sp ->> 'gen')::int then 1
                  when ln.is_mixed then 2 else 3 end, l.piece_no
    limit 1;
    if v_lap is null then raise exception 'Lot % has more sales than laptops', s ->> 'lot_key'; end if;
    update public.laptops set
      brand = coalesce(brand, sp ->> 'brand'), brand_other = case when brand_other = '' then coalesce(sp ->> 'brand_other', '') else brand_other end,
      model = case when model = '' then coalesce(sp ->> 'model', '') else model end,
      processor = coalesce(processor, sp ->> 'processor'), gen = coalesce(gen, (sp ->> 'gen')::int),
      ram_gb = coalesce(ram_gb, (sp ->> 'ram_gb')::int), storage_type = coalesce(storage_type, sp ->> 'storage_type'),
      storage_gb = coalesce(storage_gb, (sp ->> 'storage_gb')::int)
    where id = v_lap;
    perform private.do_sell(v_lap, coalesce(s ->> 'name', ''), '', '', s ->> 'lead_source', coalesce(s ->> 'customer_type', 'Retail'),
                            (s ->> 'price')::numeric, (s ->> 'price')::numeric, coalesce(s ->> 'method', 'UPI'), '',
                            (s ->> 'sold_on')::date, 0, null, null, true);
    n_sales := n_sales + 1; t_sales := t_sales + (s ->> 'price')::numeric;
  end loop;

  perform set_config('app.no_log', 'off', true);
  perform set_config('app.no_invoice', 'off', true);
  r := jsonb_build_object('lots', (select count(*) from _xl),
         'lines', (select count(*) from public.lot_lines ln join _xl on _xl.lot = ln.lot_id),
         'laptops', (select count(*) from public.laptops l join _xl on _xl.lot = l.lot_id),
         'cost', (select coalesce(sum(c.line_cost), 0) from public.lot_line_costs c join public.lot_lines ln on ln.id = c.line_id
                  join _xl on _xl.lot = ln.lot_id),
         'sales', n_sales, 'sales_total', t_sales, 'expenses', n_exp, 'expenses_total', t_exp);
  perform private.log('import', 'excel', null, format('Imported the Excel: %s lots, %s laptops, %s sales (%s), %s expenses (%s)',
          r ->> 'lots', r ->> 'laptops', n_sales, private.rs(t_sales), n_exp, private.rs(t_exp)));
  return r;
end $$;

-- ---------------------------------------------------------------------
-- 0008_admin_sql.sql
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 0008b_deletes.sql
-- ---------------------------------------------------------------------
-- 0008b: delete and restore (Recently deleted, 30 days), with the rules enforced here, not only in the app.
-- Laptops, lots, suppliers and service partners: admin only. Photos: admin and co-admin.
-- Payments are never deleted, users are turned off (not deleted), customers stay (they come from sales).
-- Safe to run twice.

-- ---------- cost helpers that must ignore deleted laptops ----------
-- This laptop's equal share of its lot's parts/expenses, shared only among laptops that are not deleted.
create or replace function private.lot_share(p_laptop uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(
           (e.amount - (select f.value from private.fitted(e.id) f))
           / nullif((select count(*) from private.live_laptops x
                     where x.lot_id = e.lot_id and (e.line_id is null or x.line_id = e.line_id)), 0)
         ), 0)
  from public.laptops l
  join public.lot_expenses e on e.lot_id = l.lot_id and e.deleted_at is null
                            and (e.line_id is null or e.line_id = l.line_id)
  where l.id = p_laptop
$$;

-- Each laptop's purchase cost from its line, split over the laptops that are not deleted.
create or replace function private.write_line_costs(p_line uuid) returns void
language plpgsql set search_path = '' as $$
declare v_cost numeric; v_n int; v_per numeric; v_last int;
begin
  select line_cost into v_cost from public.lot_line_costs where line_id = p_line;
  delete from public.laptop_costs c using private.live_laptops l where l.id = c.laptop_id and l.line_id = p_line;
  if v_cost is null then return; end if;
  select count(*), max(piece_no) into v_n, v_last from private.live_laptops where line_id = p_line;
  if v_n = 0 then return; end if;
  v_per := trunc(v_cost / v_n, 2);
  insert into public.laptop_costs (laptop_id, cost, source)
  select l.id, case when l.piece_no = v_last then v_cost - v_per * (v_n - 1) else v_per end, 'lot'
  from private.live_laptops l where l.line_id = p_line;
end $$;

create or replace function private.supplier_due(p_supplier uuid) returns numeric
language sql stable set search_path = '' as $$
  select case when s.code = '00' then 0 else
    coalesce((select sum(c.cost) from public.laptop_costs c join private.live_laptops l on l.id = c.laptop_id
              join private.live_lots lo on lo.id = l.lot_id where lo.supplier_id = s.id), 0)
  - coalesce((select sum(p.amount) from public.supplier_payments p where p.supplier_id = s.id), 0) end
  from public.suppliers s where s.id = p_supplier
$$;

-- ---------- rules ----------
-- Why a laptop must stay (null = it may be deleted). Anything with a customer or money in its history stays.
create or replace function private.laptop_block_reason(p_laptop uuid) returns text
language sql stable set search_path = '' as $$
  select case
    when exists (select 1 from public.sales where laptop_id = p_laptop and status = 'active')
      then 'This laptop has a sale. Use Undo sale or Return instead.'
    when exists (select 1 from public.returns where laptop_id = p_laptop)
      then 'This laptop was returned by a customer, so it stays in the history.'
    when exists (select 1 from public.sales where laptop_id = p_laptop)
      then 'This laptop was sold before (the sale was undone), so it stays in the history.'
    when exists (select 1 from public.bookings where laptop_id = p_laptop)
      then 'This laptop was booked by a customer, so it stays in the history.'
    when exists (select 1 from public.service_jobs where laptop_id = p_laptop)
      then 'This laptop went for service, so it stays in the history.'
    when exists (select 1 from public.laptops l join public.lots lo on lo.id = l.lot_id where l.id = p_laptop and lo.kind = 'exchange')
      then 'This laptop came in exchange on a sale. Its value is part of that sale''s payment.'
  end
$$;

-- Unsold laptops (with a cost) that would carry a deleted laptop's cost: same group first, else the same lot.
create or replace function private.cost_carriers(p_laptop uuid) returns uuid[]
language plpgsql stable set search_path = '' as $$
declare l public.laptops; v uuid[];
begin
  select * into l from public.laptops where id = p_laptop;
  select array_agg(x.id order by x.piece_no) into v from private.live_laptops x
  where x.line_id = l.line_id and x.id <> l.id and not private.is_sold(x.id)
    and exists (select 1 from public.laptop_costs c where c.laptop_id = x.id);
  if v is null then
    select array_agg(x.id order by x.piece_no) into v from private.live_laptops x
    where x.lot_id = l.lot_id and x.id <> l.id and not private.is_sold(x.id)
      and exists (select 1 from public.laptop_costs c where c.laptop_id = x.id);
  end if;
  return coalesce(v, '{}');
end $$;

-- ---------- laptop ----------
-- What the app shows before asking: may it be deleted, and the cost choice.
create or replace function public.delete_laptop_check(p_laptop_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare l public.laptops; v_cost numeric; v_carry uuid[];
begin
  perform private.require_admin();
  select * into l from private.live_laptops where id = p_laptop_id;
  if not found then raise exception 'Laptop not found'; end if;
  v_cost := private.cost_of(l.id);
  v_carry := private.cost_carriers(l.id);
  return jsonb_build_object('code', l.code, 'reason', private.laptop_block_reason(l.id),
    'cost', v_cost, 'can_keep', v_cost is not null and v_cost > 0 and cardinality(v_carry) > 0, 'keep_count', cardinality(v_carry));
end $$;

-- p_lot_cost: 'reduce' = the lot cost goes down by this laptop's cost;
--             'keep'   = the lot cost stays; this laptop's cost is shared over the other unsold laptops.
create or replace function public.delete_laptop(p_laptop_id uuid, p_lot_cost text default 'reduce', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; l public.laptops; v_why text; v_cost numeric; v_carry uuid[]; v_n int; v_per numeric; v_deltas jsonb := '[]';
        v_mode text := coalesce(p_lot_cost, 'reduce'); v_del uuid; i int; d numeric;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  if v_mode not in ('reduce', 'keep') then raise exception 'Choose reduce or keep for the lot cost'; end if;
  select * into l from public.laptops where id = p_laptop_id for update;
  if not found or l.deleted_at is not null then raise exception 'Laptop not found, or already deleted'; end if;
  v_why := private.laptop_block_reason(l.id);
  if v_why is not null then raise exception '%', v_why; end if;
  v_cost := private.cost_of(l.id);
  if v_cost is null or v_cost = 0 then v_mode := 'none';
  elsif v_mode = 'keep' then
    v_carry := private.cost_carriers(l.id); v_n := cardinality(v_carry);
    if v_n = 0 then raise exception 'There is no other unsold laptop in this lot to carry the cost. Choose to reduce the lot cost.'; end if;
    v_per := trunc(v_cost / v_n, 2);
    for i in 1 .. v_n loop
      d := case when i = v_n then v_cost - v_per * (v_n - 1) else v_per end;
      update public.laptop_costs set cost = cost + d where laptop_id = v_carry[i];
      v_deltas := v_deltas || jsonb_build_array(jsonb_build_object('id', v_carry[i], 'delta', d));
    end loop;
  else
    update public.lot_line_costs set line_cost = greatest(line_cost - v_cost, 0) where line_id = l.line_id;
  end if;
  update public.laptops set deleted_at = now(), deleted_by = auth.uid() where id = l.id;
  insert into private.deletions (kind, item_id, label, details, deleted_by)
  values ('laptop', l.id, l.code || coalesce(' · ' || nullif(concat_ws(' ', nullif(l.shorthand, ''), nullif(l.model, '')), ''), ''),
          jsonb_build_object('mode', v_mode, 'cost', v_cost, 'line_id', l.line_id, 'deltas', v_deltas), auth.uid())
  returning id into v_del;
  perform private.log('delete', 'laptop', l.code, format('Deleted laptop %s', l.code));
  if v_mode = 'reduce' then
    perform private.log('delete', 'laptop', l.code, format('Lot cost reduced by %s for deleted laptop %s', private.rs(v_cost), l.code), true);
  elsif v_mode = 'keep' then
    perform private.log('delete', 'laptop', l.code, format('Lot cost kept: %s of deleted laptop %s shared over %s other laptops', private.rs(v_cost), l.code, v_n), true);
  end if;
  v := jsonb_build_object('deletion_id', v_del, 'code', l.code, 'mode', v_mode);
  return private.idem_put(p_client_ref, v);
end $$;

-- ---------- lot ----------
create or replace function public.delete_lot_check(p_lot_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare lo public.lots;
begin
  perform private.require_admin();
  select * into lo from private.live_lots where id = p_lot_id;
  if not found then raise exception 'Lot not found'; end if;
  return jsonb_build_object('prefix', lo.prefix, 'kind', lo.kind,
    'laptops', (select count(*) from private.live_laptops where lot_id = lo.id),
    'expenses', (select count(*) from public.lot_expenses where lot_id = lo.id and deleted_at is null),
    'blockers', coalesce((select jsonb_agg(jsonb_build_object('code', x.code, 'reason', private.laptop_block_reason(x.id)) order by x.piece_no)
                          from private.live_laptops x where x.lot_id = lo.id and private.laptop_block_reason(x.id) is not null), '[]'));
end $$;

-- p_confirm must be the lot code (e.g. 01-01-11-26), typed by the admin.
create or replace function public.delete_lot(p_lot_id uuid, p_confirm text, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; lo public.lots; v_block text; v_laps uuid[]; v_exps uuid[]; v_del uuid;
begin
  perform private.require_admin();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into lo from public.lots where id = p_lot_id for update;
  if not found or lo.deleted_at is not null then raise exception 'Lot not found, or already deleted'; end if;
  if lo.kind = 'exchange' then raise exception 'The exchange lot holds laptops taken in on sales. It cannot be deleted.'; end if;
  if btrim(coalesce(p_confirm, '')) <> lo.prefix then raise exception 'Type the lot code % to confirm', lo.prefix; end if;
  select string_agg(x.code || ': ' || private.laptop_block_reason(x.id), E'\n' order by x.piece_no) into v_block
  from public.laptops x where x.lot_id = lo.id and x.deleted_at is null and private.laptop_block_reason(x.id) is not null;
  if v_block is not null then raise exception E'These laptops must stay, so the lot cannot be deleted:\n%', v_block; end if;
  with u as (update public.laptops set deleted_at = now(), deleted_by = auth.uid()
             where lot_id = lo.id and deleted_at is null returning id)
  select coalesce(array_agg(id), '{}') into v_laps from u;
  with u as (update public.lot_expenses set deleted_at = now(), deleted_by = auth.uid()
             where lot_id = lo.id and deleted_at is null returning id)
  select coalesce(array_agg(id), '{}') into v_exps from u;
  update public.lots set deleted_at = now(), deleted_by = auth.uid() where id = lo.id;
  insert into private.deletions (kind, item_id, label, details, deleted_by)
  values ('lot', lo.id, format('Lot %s, %s laptop%s', lo.prefix, cardinality(v_laps), case when cardinality(v_laps) = 1 then '' else 's' end),
          jsonb_build_object('laptops', to_jsonb(v_laps), 'expenses', to_jsonb(v_exps)), auth.uid())
  returning id into v_del;
  perform private.log('delete', 'lot', lo.prefix, format('Deleted lot %s with %s laptop%s', lo.prefix, cardinality(v_laps), case when cardinality(v_laps) = 1 then '' else 's' end));
  v := jsonb_build_object('deletion_id', v_del, 'prefix', lo.prefix, 'laptops', cardinality(v_laps));
  return private.idem_put(p_client_ref, v);
end $$;

-- ---------- supplier, service partner ----------
create or replace function public.delete_supplier(p_supplier_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.suppliers; v_del uuid; n int;
begin
  perform private.require_admin();
  select * into s from public.suppliers where id = p_supplier_id for update;
  if not found or s.deleted_at is not null then raise exception 'Supplier not found, or already deleted'; end if;
  if s.code = '00' then raise exception 'The customer exchange supplier is part of the app. It cannot be deleted.'; end if;
  select count(*) into n from public.lots where supplier_id = s.id and deleted_at is null;
  if n > 0 then raise exception 'This supplier has % lot%. Delete the lots first, or keep the supplier.', n, case when n = 1 then '' else 's' end; end if;
  if exists (select 1 from public.lots where supplier_id = s.id) then
    raise exception 'This supplier had lots before (now deleted). It stays so their sticker numbers stay unique.';
  end if;
  if exists (select 1 from public.supplier_payments where supplier_id = s.id) then
    raise exception 'This supplier has payments in the history, so it stays.';
  end if;
  update public.suppliers set deleted_at = now(), deleted_by = auth.uid() where id = s.id;
  insert into private.deletions (kind, item_id, label, deleted_by)
  values ('supplier', s.id, format('Supplier %s, %s', s.code, s.name), auth.uid()) returning id into v_del;
  perform private.log('delete', 'supplier', s.code, format('Deleted supplier %s, %s', s.code, s.name));
  return jsonb_build_object('deletion_id', v_del);
end $$;

create or replace function public.delete_service_partner(p_partner_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.service_partners; v_del uuid; v_name text;
begin
  perform private.require_admin();
  select * into p from public.service_partners where id = p_partner_id for update;
  if not found or p.deleted_at is not null then raise exception 'Service partner not found, or already deleted'; end if;
  if exists (select 1 from public.service_jobs where partner_id = p.id) then
    raise exception 'This partner has service jobs in the history. Turn them off instead.';
  end if;
  if exists (select 1 from public.service_payments where partner_id = p.id) then
    raise exception 'This partner has payments in the history. Turn them off instead.';
  end if;
  v_name := coalesce(nullif(btrim(p.shop_name), ''), p.name);
  update public.service_partners set deleted_at = now(), deleted_by = auth.uid() where id = p.id;
  insert into private.deletions (kind, item_id, label, deleted_by)
  values ('partner', p.id, 'Service partner ' || v_name, auth.uid()) returning id into v_del;
  perform private.log('delete', 'partner', p.id::text, format('Deleted service partner %s', v_name));
  return jsonb_build_object('deletion_id', v_del);
end $$;

-- ---------- photo (admin and co-admin) ----------
-- Removes the photo from the app at once. The photo-delete Edge Function then removes the Cloudinary copy
-- and reports back with photo_cloud_result. If that fails, the photo stays out of the app and the failure is logged.
create or replace function public.delete_photo(p_photo_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ph public.photos; v_code text; v_del uuid;
begin
  perform private.require_manager();
  select * into ph from public.photos where id = p_photo_id for update;
  if not found or ph.deleted_at is not null then raise exception 'Photo not found, or already deleted'; end if;
  select code into v_code from public.laptops where id = ph.laptop_id;
  update public.photos set deleted_at = now(), deleted_by = auth.uid() where id = ph.id;
  insert into private.deletions (kind, item_id, label, details, deleted_by, cloud_status)
  values ('photo', ph.id, 'Photo of ' || v_code, jsonb_build_object('url', ph.url, 'laptop_id', ph.laptop_id), auth.uid(), 'pending')
  returning id into v_del;
  perform private.log('delete', 'photo', v_code, format('Deleted a photo of %s', v_code));
  return jsonb_build_object('deletion_id', v_del, 'url', ph.url, 'code', v_code);
end $$;

-- Called only by the photo-delete Edge Function (service key) after it tried Cloudinary.
create or replace function public.photo_cloud_result(p_deletion_id uuid, p_status text, p_detail text default '')
returns void language plpgsql security definer set search_path = '' as $$
declare d private.deletions;
begin
  if p_status not in ('deleted', 'failed', 'skipped') then raise exception 'Bad status'; end if;
  update private.deletions set cloud_status = p_status,
         details = details || jsonb_build_object('cloud_detail', left(coalesce(p_detail, ''), 300))
  where id = p_deletion_id and kind = 'photo' returning * into d;
  if not found then raise exception 'Not found'; end if;
  if p_status = 'failed' then
    perform private.log('delete', 'photo', d.label, format('%s: the Cloudinary copy could not be deleted (%s). It is gone from the app.', d.label, left(coalesce(p_detail, ''), 120)));
  end if;
end $$;

-- ---------- recently deleted, restore, 30-day cleanup ----------
-- After 30 days a delete is final: photos, suppliers and partners are removed; deleted laptops and lots keep a
-- hidden row (code only) so their sticker numbers are never used again, and lose their photos and tests.
create or replace function private.purge_deleted() returns int
language plpgsql security definer set search_path = '' as $$
declare d private.deletions; n int := 0; v_laps uuid[];
begin
  perform set_config('app.purging', 'on', true);
  for d in select * from private.deletions where restored_at is null and purged_at is null
             and deleted_at < now() - interval '30 days' for update skip locked loop
    if d.kind = 'accessory' then
      null;   -- the accessory stays hidden (its stock history is kept)
    elsif d.kind = 'photo' then
      delete from public.photos where id = d.item_id and deleted_at is not null;
    elsif d.kind = 'supplier' then
      delete from public.suppliers s where s.id = d.item_id and s.deleted_at is not null
        and not exists (select 1 from public.lots where supplier_id = s.id)
        and not exists (select 1 from public.supplier_payments where supplier_id = s.id);
    elsif d.kind = 'partner' then
      delete from public.service_partners p where p.id = d.item_id and p.deleted_at is not null
        and not exists (select 1 from public.service_jobs where partner_id = p.id)
        and not exists (select 1 from public.service_payments where partner_id = p.id);
    else
      v_laps := case when d.kind = 'laptop' then array[d.item_id]
                     else array(select jsonb_array_elements_text(d.details -> 'laptops')::uuid) end;
      delete from public.photos where laptop_id = any (v_laps);
      delete from public.laptop_tests where laptop_id = any (v_laps);
    end if;
    update private.deletions set purged_at = now() where id = d.id;
    n := n + 1;
  end loop;
  perform set_config('app.purging', 'off', true);
  return n;
end $$;

create or replace function public.recently_deleted()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  perform private.purge_deleted();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'kind', d.kind, 'label', d.label, 'deleted_at', d.deleted_at,
      'by', coalesce((select name from public.profiles where id = d.deleted_by), 'Someone'),
      'days_left', greatest(0, 30 - floor(extract(epoch from now() - d.deleted_at) / 86400)::int),
      'mode', d.details ->> 'mode', 'cost', (d.details ->> 'cost')::numeric,
      'url', d.details ->> 'url', 'cloud', d.cloud_status,
      'can_restore', not (d.kind = 'photo' and d.cloud_status = 'deleted'))
    order by d.deleted_at desc)
    from private.deletions d where d.restored_at is null and d.purged_at is null), '[]');
end $$;

create or replace function public.restore_deleted(p_deletion_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d private.deletions; x jsonb; v_code text; v_lot text;
begin
  perform private.require_admin();
  select * into d from private.deletions where id = p_deletion_id for update;
  if not found or d.restored_at is not null then raise exception 'Nothing to restore'; end if;
  if d.purged_at is not null or d.deleted_at < now() - interval '30 days' then
    raise exception 'This was deleted more than 30 days ago and is gone for good.';
  end if;
  if d.kind = 'laptop' then
    select l.code, lo.prefix into v_code, v_lot from public.laptops l join public.lots lo on lo.id = l.lot_id
    where l.id = d.item_id and lo.deleted_at is not null;
    if v_lot is not null then raise exception 'Lot % is deleted. Restore the lot first.', v_lot; end if;
    for x in select * from jsonb_array_elements(d.details -> 'deltas') loop
      update public.laptop_costs set cost = greatest(cost - (x ->> 'delta')::numeric, 0) where laptop_id = (x ->> 'id')::uuid;
    end loop;
    if d.details ->> 'mode' = 'reduce' then
      update public.lot_line_costs set line_cost = line_cost + (d.details ->> 'cost')::numeric where line_id = (d.details ->> 'line_id')::uuid;
    end if;
    update public.laptops set deleted_at = null, deleted_by = null where id = d.item_id returning code into v_code;
    perform private.log('restore', 'laptop', v_code, format('Restored laptop %s', v_code));
  elsif d.kind = 'lot' then
    if exists (select 1 from public.lots lo join public.suppliers s on s.id = lo.supplier_id where lo.id = d.item_id and s.deleted_at is not null) then
      raise exception 'The supplier of this lot is deleted. Restore the supplier first.';
    end if;
    update public.lots set deleted_at = null, deleted_by = null where id = d.item_id returning prefix into v_lot;
    update public.laptops set deleted_at = null, deleted_by = null
    where id in (select jsonb_array_elements_text(d.details -> 'laptops')::uuid);
    update public.lot_expenses set deleted_at = null, deleted_by = null
    where id in (select jsonb_array_elements_text(d.details -> 'expenses')::uuid);
    perform private.log('restore', 'lot', v_lot, format('Restored lot %s', v_lot));
  elsif d.kind = 'supplier' then
    update public.suppliers set deleted_at = null, deleted_by = null where id = d.item_id returning code || ', ' || name into v_code;
    perform private.log('restore', 'supplier', d.item_id::text, format('Restored supplier %s', v_code));
  elsif d.kind = 'accessory' then
    if exists (select 1 from public.accessories x join public.accessories y on lower(btrim(y.name)) = lower(btrim(x.name))
               where x.id = d.item_id and y.id <> x.id and y.deleted_at is null) then
      raise exception 'Another accessory with this name exists now. Rename or delete it first.';
    end if;
    update public.accessories set deleted_at = null, deleted_by = null where id = d.item_id returning name into v_code;
    perform private.log('restore', 'accessory', d.item_id::text, format('Restored accessory %s', v_code));
  elsif d.kind = 'partner' then
    update public.service_partners set deleted_at = null, deleted_by = null where id = d.item_id;
    perform private.log('restore', 'partner', d.item_id::text, format('Restored service partner %s', private.partner_label(d.item_id)));
  else
    if d.cloud_status = 'deleted' then raise exception 'This photo was also removed from Cloudinary, so it cannot come back.'; end if;
    if exists (select 1 from public.photos p join public.laptops l on l.id = p.laptop_id where p.id = d.item_id and l.deleted_at is not null) then
      raise exception 'The laptop of this photo is deleted. Restore the laptop first.';
    end if;
    update public.photos set deleted_at = null, deleted_by = null where id = d.item_id;
    perform private.log('restore', 'photo', d.label, format('Restored %s', lower(left(d.label, 1)) || substr(d.label, 2)));
  end if;
  update private.deletions set restored_at = now(), restored_by = auth.uid() where id = d.id;
  return jsonb_build_object('kind', d.kind, 'label', d.label);
end $$;

-- The daily keep-alive call (GitHub Actions, 09:00 India time) also runs the 30-day cleanup.
create or replace function public.ping() returns text
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.purge_deleted();
  return 'ok ' || (select count(*) from public.settings)::text;
end $$;

-- ---------------------------------------------------------------------
-- 0008c_accessories_rpc.sql
-- ---------------------------------------------------------------------
-- 0008c: accessories (add, stock in, sell or give, adjust, delete) and notifications. Safe to run twice.
-- Who may do what: staff sell or give and see quantities; co-admin also adds stock, adjusts and edits (never sees cost);
-- admin everything, including costs, profit and delete.

-- Average cost of one unit (purchases with a cost entered). Admin only, used for profit.
create or replace function private.acc_avg_cost(p_acc uuid) returns numeric
language sql stable set search_path = '' as $$
  select round(sum(c.unit_cost * m.delta) / nullif(sum(m.delta), 0), 2)
  from public.accessory_moves m join public.accessory_move_costs c on c.move_id = m.id
  where m.accessory_id = p_acc and m.kind = 'in'
$$;
create or replace function private.acc_last_cost(p_acc uuid) returns numeric
language sql stable set search_path = '' as $$
  select c.unit_cost from public.accessory_moves m join public.accessory_move_costs c on c.move_id = m.id
  where m.accessory_id = p_acc and m.kind = 'in' order by m.created_at desc limit 1
$$;

create or replace function private.accessory_json(p_acc uuid, p_role text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', a.id, 'name', a.name, 'qty', private.acc_qty(a.id), 'alert_at', a.alert_at, 'price', a.price,
                            'low', private.acc_qty(a.id) <= a.alert_at)
  || case when p_role = 'admin' then jsonb_build_object('cost', private.acc_last_cost(a.id), 'avg_cost', private.acc_avg_cost(a.id)) else '{}'::jsonb end
  from public.accessories a where a.id = p_acc
$$;

create or replace function private.acc_lock(p_acc uuid) returns public.accessories
language plpgsql set search_path = '' as $$
declare a public.accessories;
begin
  select * into a from public.accessories where id = p_acc for update;
  if not found or a.deleted_at is not null then raise exception 'Accessory not found'; end if;
  return a;
end $$;

-- ---------- add / edit ----------
create or replace function public.add_accessory(p_name text, p_opening int default 0, p_alert int default 2,
  p_cost numeric default null, p_price numeric default null, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_id uuid; v_move uuid; r text := private.require_manager();
begin
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter the name'; end if;
  if coalesce(p_opening, 0) < 0 then raise exception 'Opening stock cannot be below 0'; end if;
  if exists (select 1 from public.accessories where lower(btrim(name)) = lower(btrim(p_name)) and deleted_at is null) then
    raise exception '% is already in the list. Tap it to add stock.', btrim(p_name);
  end if;
  insert into public.accessories (name, alert_at, price) values (btrim(p_name), greatest(coalesce(p_alert, 2), 0), p_price)
  returning id into v_id;
  if coalesce(p_opening, 0) > 0 then
    insert into public.accessory_moves (accessory_id, kind, delta, note) values (v_id, 'in', p_opening, 'Opening stock') returning id into v_move;
    if p_cost is not null then insert into public.accessory_move_costs (move_id, unit_cost) values (v_move, p_cost); end if;
  else
    perform private.acc_check_low(v_id, 'Added with no stock');
  end if;
  v := jsonb_build_object('id', v_id);
  return private.idem_put(p_client_ref, v);
end $$;

create or replace function public.save_accessory(p_id uuid, p_name text, p_alert int, p_price numeric default null)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.accessories;
begin
  perform private.require_manager();
  a := private.acc_lock(p_id);
  if btrim(coalesce(p_name, '')) = '' then raise exception 'Enter the name'; end if;
  if exists (select 1 from public.accessories where lower(btrim(name)) = lower(btrim(p_name)) and deleted_at is null and id <> p_id) then
    raise exception '% is already in the list.', btrim(p_name);
  end if;
  update public.accessories set name = btrim(p_name), alert_at = greatest(coalesce(p_alert, a.alert_at), 0), price = p_price where id = p_id;
end $$;

-- ---------- movements ----------
-- New stock bought (admin, co-admin). Cost is optional; only the admin ever sees it.
create or replace function public.accessory_in(p_id uuid, p_qty int, p_cost_each numeric default null, p_supplier_id uuid default null,
  p_on date default null, p_method text default 'Cash', p_note text default '', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_move uuid;
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  perform private.acc_lock(p_id);
  if coalesce(p_qty, 0) < 1 then raise exception 'Enter how many'; end if;
  if p_cost_each is not null and p_cost_each < 0 then raise exception 'Check the cost'; end if;
  if coalesce(p_on, private.today()) > private.today() then raise exception 'The date cannot be in the future'; end if;
  insert into public.accessory_moves (accessory_id, kind, delta, method, supplier_id, note, moved_on)
  values (p_id, 'in', p_qty, case when p_cost_each is null then null else coalesce(p_method, 'Cash') end, p_supplier_id,
          left(btrim(coalesce(p_note, '')), 300), coalesce(p_on, private.today()))
  returning id into v_move;
  if p_cost_each is not null then insert into public.accessory_move_costs (move_id, unit_cost) values (v_move, p_cost_each); end if;
  v := jsonb_build_object('qty', private.acc_qty(p_id));
  return private.idem_put(p_client_ref, v);
end $$;

create or replace function private.acc_out(p_id uuid, p_qty int, p_price_each numeric, p_free boolean, p_method text,
  p_customer text, p_mobile text, p_note text, p_sale uuid) returns void
language plpgsql set search_path = '' as $$
declare a public.accessories; q int; v_amt numeric;
begin
  a := private.acc_lock(p_id);
  if coalesce(p_qty, 0) < 1 then raise exception 'Enter how many'; end if;
  q := private.acc_qty(p_id);
  if p_qty > q then raise exception 'Only % % left.', q, a.name; end if;
  v_amt := case when coalesce(p_free, false) then 0 else round(coalesce(p_price_each, a.price, 0) * p_qty, 2) end;
  if v_amt < 0 then raise exception 'Check the price'; end if;
  insert into public.accessory_moves (accessory_id, kind, delta, amount, free, method, sale_id, customer, mobile, note)
  values (p_id, 'out', -p_qty, v_amt, coalesce(p_free, false) or v_amt = 0, case when v_amt > 0 then coalesce(p_method, 'Cash') end,
          p_sale, btrim(coalesce(p_customer, '')), regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'), left(btrim(coalesce(p_note, '')), 300));
end $$;

-- Sell or give (everyone, staff included)
create or replace function public.accessory_out(p_id uuid, p_qty int, p_price_each numeric default null, p_free boolean default false,
  p_method text default 'Cash', p_customer text default '', p_mobile text default '', p_note text default '', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  perform private.acc_out(p_id, p_qty, p_price_each, p_free, p_method, p_customer, p_mobile, p_note, null);
  v := jsonb_build_object('qty', private.acc_qty(p_id));
  return private.idem_put(p_client_ref, v);
end $$;

-- Accessories given with a laptop sale (single sale, or the bulk sale it belongs to).
-- p_items: [{"id": "...", "qty": 2, "price_each": 400}]. Free: no charge; otherwise the money is received now.
create or replace function public.give_accessories(p_sale_id uuid default null, p_bulk_group uuid default null, p_items jsonb default '[]',
  p_free boolean default true, p_method text default 'Cash', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; s public.sales; x jsonb; v_inv text;
begin
  perform private.require_user();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  select * into s from public.sales where status = 'active'
    and (id = p_sale_id or (p_bulk_group is not null and bulk_group = p_bulk_group)) order by created_at limit 1;
  if not found then raise exception 'Sale not found'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Pick the accessories'; end if;
  v_inv := case when s.invoice_no is not null then 'INV-' || s.invoice_no else '' end;
  -- lock in a fixed order, so two phones never wait on each other
  for x in select * from jsonb_array_elements(p_items) e order by e ->> 'id' loop
    perform private.acc_out((x ->> 'id')::uuid, (x ->> 'qty')::int, (x ->> 'price_each')::numeric, p_free, p_method,
                            private.cust_label(s.customer_name, s.lead_source), coalesce((select mobile from public.customers where id = s.customer_id), ''),
                            case when v_inv <> '' then 'With laptop sale ' || v_inv else 'With laptop sale' end, s.id);
  end loop;
  v := jsonb_build_object('sale_id', s.id);
  return private.idem_put(p_client_ref, v);
end $$;

-- Damaged, lost, found, count correction (admin, co-admin). Needs a reason.
create or replace function public.accessory_adjust(p_id uuid, p_delta int, p_reason text, p_note text default '', p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; a public.accessories;
begin
  perform private.require_manager();
  v := private.idem_get(p_client_ref); if v is not null then return v; end if;
  a := private.acc_lock(p_id);
  if coalesce(p_delta, 0) = 0 then raise exception 'Enter how many to add or take off'; end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception 'Choose a reason'; end if;
  if private.acc_qty(p_id) + p_delta < 0 then raise exception 'Only % % left. Stock cannot go below 0.', private.acc_qty(p_id), a.name; end if;
  insert into public.accessory_moves (accessory_id, kind, delta, reason, note)
  values (p_id, 'adjust', p_delta, left(btrim(p_reason), 60), left(btrim(coalesce(p_note, '')), 300));
  v := jsonb_build_object('qty', private.acc_qty(p_id));
  return private.idem_put(p_client_ref, v);
end $$;

-- Last movements of one accessory (who, when, note). Money only for admin and co-admin, cost only for admin.
create or replace function public.accessory_moves_list(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'delta', m.delta, 'on', m.moved_on, 'at', m.created_at,
      'by', coalesce((select name from public.profiles where id = m.created_by), 'Someone'),
      'customer', m.customer, 'free', m.free, 'reason', m.reason, 'note', m.note,
      'supplier', (select name from public.suppliers where id = m.supplier_id))
    || case when r <> 'staff' then jsonb_build_object('amount', m.amount, 'method', m.method) else '{}'::jsonb end
    || case when r = 'admin' then jsonb_build_object('unit_cost', (select unit_cost from public.accessory_move_costs where move_id = m.id)) else '{}'::jsonb end
    order by m.created_at desc)
    from (select * from public.accessory_moves where accessory_id = p_id order by created_at desc limit 60) m), '[]');
end $$;

-- Delete (admin): soft delete, in Recently deleted for 30 days. The movements stay in the history.
create or replace function public.delete_accessory(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.accessories; v_del uuid;
begin
  perform private.require_admin();
  a := private.acc_lock(p_id);
  update public.accessories set deleted_at = now(), deleted_by = auth.uid() where id = p_id;
  insert into private.deletions (kind, item_id, label, deleted_by)
  values ('accessory', p_id, format('Accessory %s (%s left)', a.name, private.acc_qty(p_id)), auth.uid()) returning id into v_del;
  perform private.log('delete', 'accessory', p_id::text, format('Deleted accessory %s', a.name));
  return jsonb_build_object('deletion_id', v_del);
end $$;

-- ---------- notifications ----------
-- Events that come from the calendar (not from one action): made when the app loads and by the daily ping.
create or replace function private.refresh_notifications() returns void
language plpgsql security definer set search_path = '' as $$
declare v_today date := private.today();
begin
  -- laptops with a service partner past the expected date
  insert into public.notifications (kind, key, title, body, link_kind, link_id, audience)
  select 'service_overdue', 'svc:' || j.id,
         format('%s at %s: %s day%s past the expected date', l.code, private.partner_label(j.partner_id),
                v_today - j.expected_on, case when v_today - j.expected_on = 1 then '' else 's' end),
         format('Given on %s, expected back %s', to_char(j.given_on, 'DD/MM/YYYY'), to_char(j.expected_on, 'DD/MM/YYYY')),
         'laptop', l.code, 'all'
  from public.service_jobs j join public.laptops l on l.id = j.laptop_id
  where j.status = 'out' and j.expected_on < v_today
  on conflict (key) do nothing;
  -- customer balances pending over 30 days
  insert into public.notifications (kind, key, title, body, link_kind, link_id, audience)
  select 'balance_pending', 'due:' || s.id,
         format('%s: %s pending %s days', private.cust_label(s.customer_name, s.lead_source), private.rs(s.price - private.sale_paid(s.id)), v_today - s.sold_on),
         format('Sold %s on %s', l.code, to_char(s.sold_on, 'DD/MM/YYYY')), 'laptop', l.code, 'mgr'
  from public.sales s join public.laptops l on l.id = s.laptop_id
  where s.status = 'active' and s.sold_on <= v_today - 30 and s.price - private.sale_paid(s.id) > 0
  on conflict (key) do nothing;
  -- advances held after a cancelled booking, waiting for the admin or co-admin
  insert into public.notifications (kind, key, title, body, link_kind, link_id, audience)
  select 'held_advance', 'held:' || b.id,
         format('Advance of %s held for %s', private.rs((select sum(amount) from public.booking_payments where booking_id = b.id)),
                private.cust_label(b.customer_name, b.lead_source)),
         format('Booking of %s was cancelled. Keep or refund the advance.', l.code), 'held', l.code, 'mgr'
  from public.bookings b join public.laptops l on l.id = b.laptop_id
  where b.advance_status = 'held'
  on conflict (key) do nothing;
end $$;

create or replace function private.notif_visible(p_audience text, p_role text) returns boolean
language sql immutable set search_path = '' as $$
  select p_audience = 'all' or (p_audience = 'mgr' and p_role in ('admin','coadmin')) or (p_audience = 'admin' and p_role = 'admin')
$$;

-- Makes the calendar notifications, then returns how many are unread for this user.
create or replace function public.notifications_check()
returns int language plpgsql security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  perform private.refresh_notifications();
  return (select count(*) from public.notifications n
          where private.notif_visible(n.audience, r) and n.created_at > now() - interval '60 days'
            and not exists (select 1 from public.notification_reads x where x.notification_id = n.id and x.user_id = auth.uid()))::int;
end $$;

create or replace function public.my_notifications()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r text := private.require_user();
begin
  perform private.refresh_notifications();
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body,
      'link_kind', n.link_kind, 'link_id', n.link_id, 'at', n.created_at,
      'read', exists (select 1 from public.notification_reads x where x.notification_id = n.id and x.user_id = auth.uid()))
    order by n.created_at desc)
    from (select * from public.notifications where private.notif_visible(audience, r) and created_at > now() - interval '60 days'
          order by created_at desc limit 100) n), '[]');
end $$;

-- p_ids null = all of this user's notifications
create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = '' as $$
declare r text := private.require_user(); n int;
begin
  insert into public.notification_reads (notification_id, user_id)
  select id, auth.uid() from public.notifications
  where private.notif_visible(audience, r) and (p_ids is null or id = any (p_ids))
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- The daily keep-alive also makes the calendar notifications and runs the 30-day cleanup
create or replace function public.ping() returns text
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.purge_deleted();
  perform private.refresh_notifications();
  return 'ok ' || (select count(*) from public.settings)::text;
end $$;

-- ---------------------------------------------------------------------
-- 0008d_export.sql
-- ---------------------------------------------------------------------
-- 0008d: exports (Excel, CSV, SQL). Safe to run twice.
-- export_sheets: readable tables for Excel and CSV, only what the caller's role may see
--   (co-admin: no costs, profit, supplier money, debts, lot or shop expenses; staff: nothing).
-- export_dump: every business row as SQL values, for a restorable .sql file (admin only).
-- Every export is written to Activity.

create or replace function private.in_range(d date, p_from date, p_to date) returns boolean
language sql immutable set search_path = '' as $$ select (p_from is null or d >= p_from) and (p_to is null or d <= p_to) $$;

-- Column list [["Header","type"],…] → [{"h","t"}]. Types: s text, i whole number, m money (₹), d date, t date and time.
create or replace function private.xcols(p jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('h', e ->> 0, 't', e ->> 1) order by n), '[]') from jsonb_array_elements(p) with ordinality as x(e, n)
$$;
create or replace function private.xsheet(p_name text, p_total boolean, p_cols jsonb, p_rows jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_array(jsonb_build_object('name', p_name, 'total', p_total, 'cols', private.xcols(p_cols), 'rows', coalesce(p_rows, '[]'::jsonb)))
$$;
-- Optional columns: the value only when the condition holds, otherwise nothing
create or replace function private.xif(p_on boolean, p jsonb) returns jsonb
language sql immutable set search_path = '' as $$ select case when p_on then p else '[]'::jsonb end $$;

create or replace function public.export_sheets(p_from date default null, p_to date default null, p_deleted boolean default false, p_format text default 'xlsx')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r text := private.require_manager(); adm boolean := r = 'admin'; del boolean := coalesce(p_deleted, false);
        sh jsonb := '[]'; f date := p_from; t date := p_to; fmt text := lower(coalesce(p_format, 'xlsx'));
begin
  if f is not null and t is not null and f > t then raise exception 'The start date is after the end date'; end if;
  if fmt not in ('xlsx', 'csv') then raise exception 'Unknown format'; end if;

  -- Lots (all of them)
  sh := sh || private.xsheet('Lots', adm,
    '[["Lot code","s"],["Supplier","s"],["Bought on","d"],["Kind","s"],["Laptops","i"],["Sold","i"]]'::jsonb
      || private.xif(adm, '[["Cost","m"]]') || '[["Note","s"]]'::jsonb || private.xif(del, '[["Deleted on","d"]]'),
    (select jsonb_agg(jsonb_build_array(lo.prefix, s.name, lo.bought_on, lo.kind,
               (select count(*) from public.laptops x where x.lot_id = lo.id and (del or x.deleted_at is null)),
               (select count(*) from public.laptops x where x.lot_id = lo.id and (del or x.deleted_at is null) and private.is_sold(x.id)))
             || private.xif(adm, jsonb_build_array((select sum(lc.cost) from public.laptop_costs lc join public.laptops x on x.id = lc.laptop_id
                                                     where x.lot_id = lo.id and (del or x.deleted_at is null))))
             || jsonb_build_array(lo.note) || private.xif(del, jsonb_build_array(lo.deleted_at::date))
             order by lo.bought_on, lo.prefix)
     from public.lots lo join public.suppliers s on s.id = lo.supplier_id where del or lo.deleted_at is null));

  -- Laptops (all of them)
  sh := sh || private.xsheet('Laptops', false,
    '[["Sticker code","s"],["Specs","s"],["Brand","s"],["Model","s"],["Processor","s"],["Gen","i"],["RAM GB","i"],["Storage","s"],["Serial","s"],["Grade","s"],["Status","s"],["Lot","s"]]'::jsonb
      || private.xif(adm, '[["Cost","m"],["Full cost","m"]]')
      || '[["Sold to","s"],["Mobile","s"],["Sale date","d"],["Price","m"],["Paid","m"],["Balance","m"],["Warranty end","d"]]'::jsonb
      || private.xif(del, '[["Deleted on","d"]]'),
    (select jsonb_agg(jsonb_build_array(l.code, l.shorthand, case when l.brand = 'Other' then l.brand_other else l.brand end, l.model,
               case when l.processor = 'Other' then l.processor_other else l.processor end, l.gen, l.ram_gb,
               nullif(concat_ws(' ', l.storage_gb, l.storage_type), ''), l.serial, l.grade,
               case when l.deleted_at is not null then 'deleted' else replace(l.status, '_', ' ') end, lo.prefix)
             || private.xif(adm, jsonb_build_array(private.cost_of(l.id), private.full_cost(l.id)))
             || jsonb_build_array(case when s.id is not null then private.cust_label(s.customer_name, s.lead_source) end, cu.mobile, s.sold_on, s.price,
                  case when s.id is not null then private.sale_paid(s.id) end, case when s.id is not null then s.price - private.sale_paid(s.id) end,
                  case when s.warranty_months > 0 then (coalesce(i.issued_on, s.sold_on) + make_interval(months => s.warranty_months))::date end)
             || private.xif(del, jsonb_build_array(l.deleted_at::date))
             order by l.created_at, l.code)
     from public.laptops l join public.lots lo on lo.id = l.lot_id
     left join public.sales s on s.laptop_id = l.id and s.status = 'active'
     left join public.customers cu on cu.id = s.customer_id
     left join public.invoices i on i.no = s.invoice_no
     where del or l.deleted_at is null));

  -- Sales (in the date range)
  sh := sh || private.xsheet('Sales', true,
    '[["Invoice","s"],["Date","d"],["Customer","s"],["Mobile","s"],["Type","s"],["Lead source","s"],["Laptop","s"],["Specs","s"],["Price","m"],["Paid","m"],["Balance","m"]]'::jsonb
      || private.xif(adm, '[["Profit","m"]]') || '[["Warranty months","i"],["Status","s"]]'::jsonb,
    (select jsonb_agg(jsonb_build_array(case when s.invoice_no is not null then 'INV-' || s.invoice_no end, s.sold_on,
               private.cust_label(s.customer_name, s.lead_source), cu.mobile, s.customer_type, s.lead_source, l.code, l.shorthand,
               s.price, private.sale_paid(s.id), case when s.status = 'active' then s.price - private.sale_paid(s.id) else 0 end)
             || private.xif(adm, jsonb_build_array(case when s.status = 'active' then private.profit(s.id) end))
             || jsonb_build_array(s.warranty_months, s.status)
             order by s.sold_on, s.created_at)
     from public.sales s join public.laptops l on l.id = s.laptop_id left join public.customers cu on cu.id = s.customer_id
     where private.in_range(s.sold_on, f, t)));

  -- Payments received (in the date range): laptop sales, advances, accessory sales
  sh := sh || private.xsheet('Payments', true,
    '[["Date","d"],["Kind","s"],["Customer","s"],["Item","s"],["Amount","m"],["Method","s"],["Ref","s"],["Note","s"]]'::jsonb,
    (select jsonb_agg(jsonb_build_array(x.d, x.k, x.c, x.i, x.a, x.m, x.r, x.n) order by x.d, x.at) from (
       select p.paid_on d, case when p.reversal_of is not null then 'Reversal' else 'Sale payment' end k,
              private.cust_label(s.customer_name, s.lead_source) c, l.code i, p.amount a, p.method m, p.ref r, p.note n, p.created_at at
       from public.sale_payments p join public.sales s on s.id = p.sale_id join public.laptops l on l.id = s.laptop_id
       where p.booking_payment_id is null and private.in_range(p.paid_on, f, t)
       union all
       select bp.paid_on, 'Advance', private.cust_label(b.customer_name, b.lead_source), l.code, bp.amount, bp.method, bp.ref, bp.note, bp.created_at
       from public.booking_payments bp join public.bookings b on b.id = bp.booking_id join public.laptops l on l.id = b.laptop_id
       where private.in_range(bp.paid_on, f, t)
       union all
       select m.moved_on, 'Accessory sale', nullif(m.customer, ''), (-m.delta) || ' × ' || a.name, m.amount, m.method, '', m.note, m.created_at
       from public.accessory_moves m join public.accessories a on a.id = m.accessory_id
       where m.kind = 'out' and m.amount > 0 and private.in_range(m.moved_on, f, t)) x));

  -- Customers (all of them)
  sh := sh || private.xsheet('Customers', true,
    '[["Name","s"],["Mobile","s"],["Type","s"],["Lead source","s"],["Laptops bought","i"],["Total bought","m"],["Paid","m"],["Balance","m"]]'::jsonb,
    (select jsonb_agg(jsonb_build_array(x.name, x.mobile, x.ctype, x.lead, x.n, x.total, x.paid, x.total - x.paid) order by x.name)
     from (select coalesce(nullif(c.name, ''), (select private.cust_label(s2.customer_name, s2.lead_source) from public.sales s2
                                                where s2.customer_id = c.id order by s2.sold_on desc limit 1)) name,
                  c.mobile, c.customer_type ctype,
                  (select s2.lead_source from public.sales s2 where s2.customer_id = c.id order by s2.sold_on desc limit 1) lead,
                  count(s.id) n, coalesce(sum(s.price), 0) total, coalesce(sum(private.sale_paid(s.id)), 0) paid
           from public.customers c left join public.sales s on s.customer_id = c.id and s.status = 'active'
           group by c.id) x));

  -- Suppliers (money only for the admin)
  sh := sh || private.xsheet('Suppliers', adm,
    '[["Code","s"],["Name","s"],["Phone","s"],["Lots","i"]]'::jsonb || private.xif(adm, '[["Bought","m"],["Paid","m"],["Owed","m"]]')
      || private.xif(del, '[["Deleted on","d"]]'),
    (select jsonb_agg(jsonb_build_array(s.code, s.name, s.phone, (select count(*) from public.lots lo where lo.supplier_id = s.id and (del or lo.deleted_at is null)))
             || private.xif(adm, jsonb_build_array(
                  (select coalesce(sum(lc.cost), 0) from public.laptop_costs lc join private.live_laptops x on x.id = lc.laptop_id join private.live_lots lo on lo.id = x.lot_id where lo.supplier_id = s.id),
                  (select coalesce(sum(amount), 0) from public.supplier_payments where supplier_id = s.id), private.supplier_due(s.id)))
             || private.xif(del, jsonb_build_array(s.deleted_at::date))
             order by s.code)
     from public.suppliers s where del or s.deleted_at is null));

  if adm then
    sh := sh || private.xsheet('Supplier payments', true,
      '[["Date","d"],["Supplier","s"],["Amount","m"],["Method","s"],["Ref","s"],["Note","s"]]'::jsonb,
      (select jsonb_agg(jsonb_build_array(p.paid_on, s.code || ', ' || s.name, p.amount, p.method, p.ref, p.note) order by p.paid_on, p.created_at)
       from public.supplier_payments p join public.suppliers s on s.id = p.supplier_id where private.in_range(p.paid_on, f, t)));
    sh := sh || private.xsheet('Lot expenses', true,
      '[["Date","d"],["Lot","s"],["Type","s"],["Count","i"],["Amount","m"],["Method","s"],["Ref","s"],["Note","s"]]'::jsonb || private.xif(del, '[["Deleted on","d"]]'),
      (select jsonb_agg(jsonb_build_array(e.spent_on, lo.prefix, e.type, e.count, e.amount, e.method, e.ref, e.note) || private.xif(del, jsonb_build_array(e.deleted_at::date))
                        order by e.spent_on, e.created_at)
       from public.lot_expenses e join public.lots lo on lo.id = e.lot_id where (del or e.deleted_at is null) and private.in_range(e.spent_on, f, t)));
    sh := sh || private.xsheet('Shop expenses', true,
      '[["Date","d"],["Type","s"],["Amount","m"],["Method","s"],["Ref","s"],["Note","s"],["From Liabilities","s"]]'::jsonb,
      (select jsonb_agg(jsonb_build_array(x.spent_on, x.type, x.amount, x.method, x.ref, x.note, case when x.from_liabilities then 'Yes' else '' end) order by x.spent_on)
       from private.shop_expense_rows(coalesce(f, '1900-01-01'), coalesce(t, '2999-12-31')) x));
    sh := sh || private.xsheet('Liabilities', true,
      '[["Name","s"],["Type","s"],["Amount","m"],["Due date","d"],["Paid","m"],["Balance","m"]]'::jsonb,
      (select jsonb_agg(jsonb_build_array(d.name, d.type, d.amount, d.due_on, x.paid, d.amount - x.paid) order by d.created_at)
       from public.debts d, lateral (select coalesce(sum(amount), 0) paid from public.debt_payments where debt_id = d.id) x where d.deleted_at is null));
    sh := sh || private.xsheet('Liability payments', true,
      '[["Date","d"],["Liability","s"],["Amount","m"],["Method","s"],["Ref","s"],["Note","s"]]'::jsonb,
      (select jsonb_agg(jsonb_build_array(p.paid_on, d.name, p.amount, p.method, p.ref, p.note) order by p.paid_on, p.created_at)
       from public.debt_payments p join public.debts d on d.id = p.debt_id where private.in_range(p.paid_on, f, t)));
  end if;

  -- Service partners and jobs
  sh := sh || private.xsheet('Service partners', adm,
    '[["Name","s"],["Shop","s"],["Mobile","s"],["Address","s"],["Skills","s"],["Active","s"],["Laptops sent","i"]]'::jsonb
      || private.xif(adm, '[["Charges","m"],["Paid","m"],["Owed","m"]]') || private.xif(del, '[["Deleted on","d"]]'),
    (select jsonb_agg(jsonb_build_array(p.name, p.shop_name, p.mobile, p.address, array_to_string(p.skills, ', '), case when p.active then 'Yes' else 'No' end,
               (select count(*) from public.service_jobs j where j.partner_id = p.id))
             || private.xif(adm, jsonb_build_array(
                  (select coalesce(sum(c.charge), 0) from public.service_jobs j join public.service_charges c on c.job_id = j.id where j.partner_id = p.id),
                  (select coalesce(sum(amount), 0) from public.service_payments where partner_id = p.id), private.partner_owed(p.id)))
             || private.xif(del, jsonb_build_array(p.deleted_at::date))
             order by p.name)
     from public.service_partners p where del or p.deleted_at is null));
  sh := sh || private.xsheet('Service jobs', adm,
    '[["Laptop","s"],["Partner","s"],["Kind","s"],["Problems","s"],["Note","s"],["Given","d"],["Expected","d"],["Received","d"],["Outcome","s"],["Work done","s"]]'::jsonb
      || private.xif(adm, '[["Charge","m"]]'),
    (select jsonb_agg(jsonb_build_array(l.code, private.partner_label(j.partner_id), j.kind, array_to_string(j.issues, ', '), j.note, j.given_on, j.expected_on,
               j.received_on, replace(coalesce(j.outcome, ''), '_', ' '), j.work_done)
             || private.xif(adm, jsonb_build_array((select charge from public.service_charges where job_id = j.id)))
             order by j.given_on, j.created_at)
     from public.service_jobs j join public.laptops l on l.id = j.laptop_id where private.in_range(j.given_on, f, t)));

  -- Accessories and stock movements
  sh := sh || private.xsheet('Accessories', false,
    '[["Name","s"],["In stock","i"],["Alert at","i"],["Selling price","m"]]'::jsonb || private.xif(adm, '[["Average cost","m"]]') || private.xif(del, '[["Deleted on","d"]]'),
    (select jsonb_agg(jsonb_build_array(a.name, private.acc_qty(a.id), a.alert_at, a.price) || private.xif(adm, jsonb_build_array(private.acc_avg_cost(a.id)))
                      || private.xif(del, jsonb_build_array(a.deleted_at::date)) order by lower(a.name))
     from public.accessories a where del or a.deleted_at is null));
  sh := sh || private.xsheet('Stock movements', true,
    '[["Date","d"],["Accessory","s"],["Kind","s"],["Change","i"],["Amount","m"],["Free","s"],["Method","s"],["Customer","s"],["Supplier","s"],["Reason","s"],["Note","s"],["By","s"]]'::jsonb
      || private.xif(adm, '[["Unit cost","m"]]'),
    (select jsonb_agg(jsonb_build_array(m.moved_on, a.name, m.kind, m.delta, m.amount, case when m.free then 'Yes' else '' end, m.method, m.customer,
               (select name from public.suppliers where id = m.supplier_id), m.reason, m.note, (select name from public.profiles where id = m.created_by))
             || private.xif(adm, jsonb_build_array((select unit_cost from public.accessory_move_costs where move_id = m.id)))
             order by m.moved_on, m.created_at)
     from public.accessory_moves m join public.accessories a on a.id = m.accessory_id where private.in_range(m.moved_on, f, t)));

  -- Activity (co-admin: without the admin-only lines)
  sh := sh || private.xsheet('Activity', false,
    '[["Time","t"],["Who","s"],["Role","s"],["What","s"]]'::jsonb,
    (select jsonb_agg(jsonb_build_array(to_char(a.at at time zone 'Asia/Kolkata', 'YYYY-MM-DD"T"HH24:MI:SS'), a.actor_name, a.actor_role, a.message) order by a.id)
     from public.activity_log a where (adm or not a.admin_only) and private.in_range((a.at at time zone 'Asia/Kolkata')::date, f, t)));

  perform private.log('export', 'export', fmt, format('Exported %s (%s%s)', case when fmt = 'xlsx' then 'Excel' else 'CSV' end,
    case when f is null and t is null then 'all time' else concat_ws(' to ', to_char(coalesce(f, '1900-01-01'), 'DD-MM-YYYY'), to_char(coalesce(t, private.today()), 'DD-MM-YYYY')) end,
    case when del then ', with deleted items' else '' end));
  return jsonb_build_object('role', r, 'from', f, 'to', t, 'deleted', del, 'exported_at', now(), 'sheets', sh);
end $$;

-- ---------- SQL dump (admin) ----------
-- Tables in load order (parents first), as the backup uses, plus Recently deleted. Read state of notifications is
-- per login, so it is not carried over. Columns that point at a login (created_by …) are left empty: logins are not exported.
create or replace function private.dump_tables() returns text[] language sql immutable as $$
  select array(select 'public.' || x from unnest(private.backup_tables()) x where x <> 'notification_reads') || array['private.deletions']
$$;

create or replace function public.export_dump()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t text; sch text; tb text; cols text; vals text; v jsonb; out jsonb := '[]';
        users text[] := array['created_by','updated_by','deleted_by','voided_by','entered_by','given_by','received_by','advance_decided_by','actor_id','restored_by'];
begin
  perform private.require_admin();
  foreach t in array private.dump_tables() loop
    sch := split_part(t, '.', 1); tb := split_part(t, '.', 2);
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
           string_agg(case when c.column_name = any (users) then '''NULL''' else format('quote_nullable(x.%I::text)', c.column_name) end,
                      ' || '', '' || ' order by c.ordinal_position)
      into cols, vals
    from information_schema.columns c
    where c.table_schema = sch and c.table_name = tb and c.is_generated = 'NEVER' and c.is_identity = 'NO';
    execute format('select coalesce(jsonb_agg(''('' || %s || '')'' order by %s), ''[]'') from %I.%I x', vals,
                   case when tb = 'activity_log' then 'x.id' when tb = 'deletions' then 'x.deleted_at' else 'x.created_at, x.ctid' end, sch, tb) into v;
    out := out || jsonb_build_array(jsonb_build_object('table', t, 'cols', cols, 'rows', v));
  end loop;
  perform private.log('export', 'export', 'sql', 'Exported a SQL backup (all data)');
  return jsonb_build_object('exported_at', now(), 'tables', out);
end $$;

-- ---------------------------------------------------------------------
-- 0009_seed_grants.sql
-- ---------------------------------------------------------------------
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
-- The photo-delete Edge Function reports what Cloudinary said (service key only).
revoke execute on function public.photo_cloud_result(uuid, text, text) from authenticated;
grant execute on function public.photo_cloud_result(uuid, text, text) to service_role;
-- The daily keep-alive call is the only thing the public key may run.
grant execute on function public.ping() to anon;
alter default privileges in schema public revoke execute on functions from public, anon;

-- ---------------------------------------------------------------------
-- Check: both numbers must be the same (every table has its access rules on)
-- ---------------------------------------------------------------------
select count(*) as tables, count(*) filter (where c.relrowsecurity) as tables_with_rls_on
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r';
