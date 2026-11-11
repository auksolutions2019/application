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
