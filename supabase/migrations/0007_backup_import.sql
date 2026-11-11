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
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t text; v jsonb; tabs jsonb := '{}';
begin
  perform private.require_admin();
  foreach t in array private.backup_tables() loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x) order by %s), ''[]'') from public.%I x',
                   case when t = 'activity_log' then 'x.id' else 'x.created_at' end, t) into v;
    tabs := tabs || jsonb_build_object(t, v);
  end loop;
  -- Recently deleted (30 days), so a restored backup can still restore those items
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
